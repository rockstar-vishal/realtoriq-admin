# frozen_string_literal: true

require "csv"

module Matches
  # Old matching against anchor matching, for a local copy of production.
  # Pass 2 runs inside a transaction and rolls back, so the switch and the
  # neighbor pairs are unchanged afterwards. The output uses firm names and
  # lead codes, never a client's name, phone or email.
  class CompareAnchors
    class Refused < StandardError; end

    HEADERS = [
      "firm name", "lead code", "anchors", "old count", "new count",
      "added", "removed", "old top 5", "new top 5"
    ].freeze

    def self.call(radius_m: Inventory::Geo::ANCHOR_DEFAULT_M, io: $stdout)
      new(radius_m:, io:).call
    end

    def initialize(radius_m:, io:)
      @radius_m = Integer(radius_m)
      @io = io
    end

    def call
      raise Refused, "matches:anchor_compare cannot run in production" if Rails.env.production?
      raise ArgumentError, "Radius must be between 1000 and 6000" unless SetAnchorRadius::RANGE.cover?(radius_m)

      leads = candidate_leads
      old = snapshot(leads)
      fresh = nil
      ActiveRecord::Base.transaction do
        ::AnchorMatching.enable!
        ::AnchorMatching.set_radius!(radius_m)
        Inventory::RebuildLocalityNeighbors.rebuild_all(across_cities: true)
        fresh = snapshot(leads)
        raise ActiveRecord::Rollback
      end
      report(leads, old, fresh)
    end

    private

    attr_reader :radius_m, :io

    def candidate_leads
      firm_ids = Eligible.firms.select(:id)
      base = Lead.unscoped.matchable.where(firm_id: firm_ids)
      ids = base.where.not(near_lat: nil).where.not(near_lng: nil).pluck(:id)
      visit_projects = LeadVisit.unscoped.where(id: LeadVisitProject.unscoped.select(:lead_visit_id)).select(:lead_id)
      visit_properties = LeadVisit.unscoped.where(id: LeadVisitProperty.unscoped.select(:lead_visit_id)).select(:lead_id)
      ids |= base.where(id: visit_projects).pluck(:id)
      ids |= base.where(id: visit_properties).pluck(:id)
      ids |= base.where(id: LeadProject.unscoped.where(withdrawn_at: nil).select(:lead_id)).pluck(:id)
      ids |= base.where(id: LeadProperty.unscoped.select(:lead_id)).pluck(:id)
      Lead.unscoped.where(id: ids).includes(:firm).order(:code).to_a
    end

    def snapshot(leads)
      leads.to_h do |lead|
        result = Current.set(firm: lead.firm) { Inventory::MatchInventory.new(lead:).result }
        rows = result[:matches].map { |row|
          {
            id: "#{row[:kind]}:#{row[:id]}",
            name: row[:name],
            score: row[:score],
            band: band_for(row),
            distance: row[:distance_m]
          }
        }
        anchors = Array(result[:anchors]).map { |anchor| "#{anchor[:kind]}:#{anchor[:name]}" }.join("|")
        [ lead.id, { rows:, anchors: } ]
      end
    end

    def band_for(row)
      return "anchor" if row[:anchor]
      return "pin" if row[:near_shortlist]
      return "preferred" if row[:group] == "locality"

      "neighbor"
    end

    def report(leads, old, fresh)
      totals = blank_counts
      by_firm = Hash.new { |hash, name| hash[name] = blank_counts }
      path = Rails.root.join("tmp/anchor_compare.csv")
      FileUtils.mkdir_p(path.dirname)
      CSV.open(path, "w") do |csv|
        csv << HEADERS
        leads.each do |lead|
          before = old[lead.id]
          after = fresh[lead.id]
          added = after[:rows].reject { |row| ids_of(before).include?(row[:id]) }
          removed = before[:rows].reject { |row| ids_of(after).include?(row[:id]) }
          top3 = before[:rows].first(3).map { |row| row[:id] } != after[:rows].first(3).map { |row| row[:id] }
          changed = added.any? || removed.any? || top3 || signature(before) != signature(after)
          bucket = by_firm[lead.firm&.name]
          add_counts(totals, bucket, added.size, removed.size, changed, top3)
          csv << [
            lead.firm&.name, lead.code, after[:anchors],
            before[:rows].size, after[:rows].size,
            added.map { |row| describe(row) }.join(" | "),
            removed.map { |row| describe(row) }.join(" | "),
            before[:rows].first(5).map { |row| row[:name] }.join(" | "),
            after[:rows].first(5).map { |row| row[:name] }.join(" | ")
          ]
        end
      end
      print_counts("overall", totals)
      by_firm.each { |name, counts| print_counts(name, counts) }
    end

    def blank_counts
      { compared: 0, changed: 0, added: 0, removed: 0, top3: 0 }
    end

    def add_counts(totals, bucket, added, removed, changed, top3)
      [ totals, bucket ].each do |counts|
        counts[:compared] += 1
        counts[:changed] += 1 if changed
        counts[:added] += added
        counts[:removed] += removed
        counts[:top3] += 1 if top3
      end
    end

    def print_counts(label, counts)
      io.puts [
        label,
        "leads compared", counts[:compared],
        "leads changed", counts[:changed],
        "rows added", counts[:added],
        "rows removed", counts[:removed],
        "top 3 changed", counts[:top3]
      ].join("\t")
    end

    def ids_of(side)
      side[:rows].map { |row| row[:id] }
    end

    def signature(side)
      side[:rows].map { |row| [ row[:id], row[:score], row[:band], row[:distance] ] }
    end

    def describe(row)
      "#{row[:name]} (#{row[:score]}, #{row[:band]}, #{row[:distance] || 'nil'})"
    end
  end
end
