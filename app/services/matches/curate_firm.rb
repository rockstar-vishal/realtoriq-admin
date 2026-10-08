# frozen_string_literal: true

module Matches
  # One pass over a firm's leads and its own listings. MatchScore, the locality
  # gate, the floors, and the possession rules are the live matcher's. Already
  # linked rows are left out in both directions. MatchLeads still returns them.
  class CurateFirm
    LEAD_CAP = 30
    LISTING_CAP = 30
    MATCH_CAP = Inventory::MatchInventory::LIMIT
    PRICE_BAND = BigDecimal("1.25")

    def self.call(firm:)
      new(firm:).call
    end

    def self.fingerprint(lead_items, listing_items)
      payload = {
        leads: lead_items.map { |item| [ item["lead_id"], item["match_ids"].sort ] }.sort,
        listings: listing_items.map { |item| [ item["kind"], item["id"], item["match_ids"].sort ] }.sort
      }
      Digest::SHA256.hexdigest(JSON.generate(payload))
    end

    def initialize(firm:)
      @firm = firm
    end

    def call
      return unless Current.firm_id == firm.id
      return unless Eligible.firm?(firm)

      previous = MatchDigest.find_by(firm_id: firm.id)
      lead_items, listing_items = items_for(previous)
      fingerprint = self.class.fingerprint(lead_items, listing_items)
      save(previous, lead_items, listing_items, fingerprint)
    end

    private

    attr_reader :firm

    def items_for(previous)
      locality_ids = matching_leads.joins(:lead_localities).distinct.pluck("lead_localities.locality_id")
      return [ [], [] ] if locality_ids.empty?

      pool = InventoryPool.call(locality_ids:, price_cap:)
      previous_leads = index_items(previous&.lead_items, "lead_id")
      previous_listings = index_listings(previous&.listing_items)
      buckets = {}
      lead_items = []

      matching_leads.find_in_batches(batch_size: 100) do |batch|
        preload_leads(batch)
        batch.each do |lead|
          scored = score_lead(lead, pool)
          next if scored.empty?

          scored.each { |row| collect_listing(buckets, lead, row) }
          lead_items << lead_item(lead, scored, previous_leads[lead.id])
        end
      end

      [ top_leads(lead_items), top_listings(buckets, previous_listings) ]
    end

    def preload_leads(batch)
      ActiveRecord::Associations::Preloader.new(
        records: batch,
        associations: [ :typologies, :localities, :property_type, :lead_status, :lead_projects, :lead_properties ]
      ).call
    end

    def price_cap
      max = matching_leads.pick(Arel.sql("MAX(COALESCE(budget_max, budget_min))"))
      return if max.nil?

      (max.to_d * PRICE_BAND).ceil.to_i
    end

    def score_lead(lead, pool)
      locality_ids = lead.localities.map(&:id)
      return [] if locality_ids.empty?

      keys = lead.typologies.map { |typology| Inventory::ConfigurationKey.call(typology.name) }
      mapped_projects = lead.lead_projects.reject { |row| row.withdrawn_at.present? }.map(&:project_id).to_set
      mapped_properties = lead.lead_properties.map(&:property_id).to_set
      candidates = candidates_for(lead, pool, locality_ids)

      candidates.filter_map { |item| scored_row(item, lead, keys, mapped_projects, mapped_properties) }
        .sort_by { |row| [ -row[:score], row[:item].name.to_s.downcase, row[:item].id.to_s ] }
        .first(MATCH_CAP)
    end

    def candidates_for(lead, pool, locality_ids)
      chosen = []
      unless lead.rent?
        chosen.concat(pool[:projects].select { |item| show_project?(lead, item, locality_ids) })
      end
      unless lead.sale? && !lead.ready_possession?
        chosen.concat(pool[:properties].select { |item| show_property?(lead, item, locality_ids) })
      end
      chosen
    end

    def show_project?(lead, item, locality_ids)
      locality_ids.include?(item.locality_id) && (!lead.ready_possession? || item.ready)
    end

    def show_property?(lead, item, locality_ids)
      locality_ids.include?(item.locality_id) && item.listing_for == lead.transaction_type
    end

    def scored_row(item, lead, keys, mapped_projects, mapped_properties)
      return if item.kind == "project" && mapped_projects.include?(item.id)
      return if item.kind == "property" && mapped_properties.include?(item.id)

      breakdown = Inventory::MatchScore.for_offers(
        budget: lead.budget_amount,
        offers: item.offers,
        lead_keys: keys,
        fallback_price: item.fallback_price
      )
      return unless breakdown[:score] > item.floor

      { item:, score: breakdown[:score] }
    end

    def collect_listing(buckets, lead, row)
      item = row[:item]
      return if item.marketplace

      key = [ item.kind, item.id ]
      bucket = buckets[key] ||= {
        "kind" => item.kind, "id" => item.id, "title" => item.name,
        "listing_for" => item.listing_for, "leads" => []
      }
      bucket["leads"] << { "lead_id" => lead.id, "name" => lead.display_name, "score" => row[:score] }
    end

    def lead_item(lead, scored, previous)
      match_ids = scored.map { |row| "#{row[:item].kind}:#{row[:item].id}" }
      {
        "lead_id" => lead.id,
        "code" => lead.code,
        "name" => lead.display_name,
        "budget" => lead.budget_amount,
        "typologies" => lead.typologies.map(&:name).sort,
        "localities" => lead.localities.map(&:name).sort,
        "dead" => lead.lead_status&.is_dead? == true,
        "match_count" => match_ids.size,
        "new_count" => new_count(match_ids, previous&.dig("match_ids")),
        "top_score" => scored.first[:score],
        "match_ids" => match_ids
      }
    end

    def top_leads(items)
      items.sort_by { |item| [ -item["top_score"], item["name"].to_s.downcase, item["lead_id"].to_s ] }
        .first(LEAD_CAP)
    end

    def top_listings(buckets, previous_listings)
      buckets.values.filter_map { |bucket| listing_item(bucket, previous_listings) }
        .sort_by { |item| [ -item["top_score"], item["title"].to_s.downcase, item["id"].to_s ] }
        .first(LISTING_CAP)
    end

    def listing_item(bucket, previous_listings)
      leads = bucket["leads"].sort_by { |row| [ -row["score"], row["name"].to_s.downcase, row["lead_id"].to_s ] }
        .first(MATCH_CAP)
      return if leads.empty?

      match_ids = leads.map { |row| row["lead_id"] }
      previous = previous_listings[[ bucket["kind"], bucket["id"] ]]
      item = {
        "kind" => bucket["kind"],
        "id" => bucket["id"],
        "title" => bucket["title"],
        "match_count" => match_ids.size,
        "new_count" => new_count(match_ids, previous&.dig("match_ids")),
        "top_score" => leads.first["score"],
        "match_ids" => match_ids
      }
      item["listing_for"] = bucket["listing_for"] if bucket["listing_for"].present?
      item
    end

    def new_count(ids, previous_ids)
      previous = Array(previous_ids).to_set
      ids.count { |id| !previous.include?(id) }
    end

    # Booked leads are a closed deal. Dead leads stay, and the page marks them.
    def matching_leads
      Lead.matchable
    end

    def index_items(items, key)
      Array(items).index_by { |item| item[key] }
    end

    def index_listings(items)
      Array(items).index_by { |item| [ item["kind"], item["id"] ] }
    end

    # `previous` is the row this scan started with. The morning release can
    # send that ping and clear the flag while scoring is still running, so the
    # decision re-reads the row under a lock. Writing the stale flag back is
    # what queued a second ping for a list that had already been sent.
    def save(_previous, lead_items, listing_items, fingerprint)
      attempts = 0
      begin
        MatchDigest.transaction do
          current = MatchDigest.lock.find_by(firm_id: firm.id)
          announce = announce?(lead_items, listing_items, current)
          digest = current || MatchDigest.new(firm:)
          digest.assign_attributes(generated_at: Time.current, fingerprint:, lead_items:, listing_items:)
          apply_notification(digest, current, announce)
          digest.save!
          digest
        end
      rescue ActiveRecord::RecordNotUnique
        attempts += 1
        retry if attempts < 2

        raise
      end
    end

    def announce?(lead_items, listing_items, previous)
      return false if lead_items.empty? && listing_items.empty?
      return true if previous.nil?

      new_total(lead_items, listing_items).positive?
    end

    def new_total(lead_items, listing_items)
      (lead_items + listing_items).sum { |item| item["new_count"].to_i }
    end

    def apply_notification(digest, previous, announce)
      if announce && Slot.quiet?
        digest.notification_pending = true
      elsif announce
        Notify.call(digest:)
        digest.notification_pending = false
        digest.notified_fingerprint = digest.fingerprint
      else
        still_waiting = previous&.notification_pending && (digest.lead_items.any? || digest.listing_items.any?)
        digest.notification_pending = still_waiting == true
      end
    end
  end
end
