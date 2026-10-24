# frozen_string_literal: true

module Form6
  # The bookings and projects a half-year report is built from. Table B is
  # live bookings on a project, booked inside the half, oldest first.
  # Cancelled bookings and bookings with no project are counted and left out.
  class Report
    attr_reader :firm, :period

    def initialize(firm:, period:)
      @firm = firm
      @period = period
    end

    def period_bookings
      firm.bookings.where(booked_on: period.from..period.to)
    end

    def table_b_rows
      @table_b_rows ||= period_bookings.live.where.not(project_id: nil)
        .includes(:project, :typology)
        .order(:booked_on, :created_at, :id)
        .to_a
    end

    def cancelled_count
      period_bookings.where(status: "cancelled").count
    end

    def without_project_count
      period_bookings.live.where(project_id: nil).count
    end

    def designated_projects
      @designated_projects ||= begin
        ids = Array(Settings.read(firm)["designated_project_ids"])
        found = Settings.projects_for(firm, ids)
        ids.filter_map { |id| found[id.to_s.downcase] }
      end
    end

    def projects_without_rera
      seen = {}
      (designated_projects + table_b_rows.filter_map(&:project)).filter_map do |project|
        next if seen[project.id] || project.rera_number.present?

        seen[project.id] = true
        { id: project.id, name: project.name }
      end
    end

    def bookings_without_configuration
      table_b_rows.filter_map do |booking|
        next if booking.typology_id.present?

        { id: booking.id, customer_name: booking.customer_name }
      end
    end
  end
end
