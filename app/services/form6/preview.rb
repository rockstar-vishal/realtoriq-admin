# frozen_string_literal: true

module Form6
  class Preview
    def initialize(firm:, period:)
      @firm = firm
      @period = period
      @report = Report.new(firm:, period:)
    end

    def as_json(*)
      {
        period: period.as_json,
        bookings_count: report.table_b_rows.size,
        left_out: {
          cancelled: report.cancelled_count,
          without_project: report.without_project_count
        },
        designated_projects_count: report.designated_projects.size,
        gaps: {
          projects_without_rera: report.projects_without_rera,
          bookings_without_configuration: report.bookings_without_configuration,
          missing_settings: Settings.missing_keys(firm)
        },
        filename: Document.filename_for(firm:, period:)
      }
    end

    private

    attr_reader :firm, :period, :report
  end
end
