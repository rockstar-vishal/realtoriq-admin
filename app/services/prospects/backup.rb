# frozen_string_literal: true

require "csv"

module Prospects
  # The spreadsheet a manager downloads before clearing. Columns match the
  # import, plus status, next call, and lead code. Import ignores the extras,
  # so a clear followed by an import brings the people back as New.
  class Backup
    HEADERS = [
      "Client name", "Client number", "Comment", "Project code", "Property code",
      "Status", "Next call", "Lead code"
    ].freeze

    STATUS_LABELS = {
      "new" => "New",
      "following" => "Following",
      "interested" => "Interested",
      "not_interested" => "Not interested"
    }.freeze

    Result = Struct.new(:ok?, :csv, :error_code, :error_message, keyword_init: true)

    def initialize(actor:, statuses:)
      @actor = actor
      @statuses = Array(statuses).map(&:to_s) & Prospect::STATUSES
    end

    def call
      unless actor.super_admin? || actor.manager?
        return Result.new(ok?: false, error_code: "forbidden_role",
          error_message: "Only a manager can download a prospect backup.")
      end
      if statuses.empty?
        return Result.new(ok?: false, error_code: "invalid",
          error_message: "Choose at least one status to download.")
      end

      rows = Prospect.where(status: statuses).includes(:project, :property, :lead).order(:created_at, :id)
      Result.new(ok?: true, csv: render(rows))
    end

    private

    attr_reader :actor, :statuses

    def render(rows)
      CSV.generate do |csv|
        csv << HEADERS
        rows.each do |prospect|
          csv << [
            cell(prospect.name),
            cell(prospect.mobile),
            cell(prospect.comment),
            cell(prospect.project&.code),
            cell(prospect.property&.code),
            cell(STATUS_LABELS[prospect.status]),
            cell(prospect.next_action_at&.iso8601),
            cell(prospect.lead&.code)
          ]
        end
      end
    end

    # A cell that starts with one of these is a formula when Excel opens the file.
    def cell(value)
      text = value.to_s
      text.match?(/\A[=+\-@]/) ? "'#{text}" : text
    end
  end
end
