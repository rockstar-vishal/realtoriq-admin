# frozen_string_literal: true

module Realtoriq
  # Asks LaunchIQ for an external visit pass and stores it on the lead.
  # The pass row is inserted first, and its id is the idempotency key, so a
  # lost response is retried as the same pass rather than a second one.
  class CreateVisitPass
    Result = Struct.new(:ok?, :status, :error_code, :error_message, :pass, :details, keyword_init: true)

    TURBO_CODE = /\APR[0-9A-F]+\z/i

    def self.call(...)
      new(...).call
    end

    def initialize(lead:, user:, project_id:, tentative_visit_planned:)
      @lead = lead
      @user = user
      @project_id = project_id
      @tentative_visit_planned = tentative_visit_planned
    end

    def call
      if lead.firm&.review_demo? || user.firm&.review_demo?
        return Result.new(
          ok?: false,
          status: :forbidden,
          error_code: "demo_account_restricted",
          error_message: "Not available in the demo account."
        )
      end

      project = mapped_project
      return project if project.is_a?(Result)

      when_at = parse_time
      if when_at.nil? || when_at < 1.day.ago
        return failure("invalid", "Visit time is missing or more than a day in the past.")
      end

      suffix = lead.mobile.to_s.gsub(/\D/, "").last(5)
      return failure("invalid", "The lead mobile needs a 10-digit number.") unless suffix.match?(/\A\d{5}\z/)

      rera = user.rera_number.presence || user.firm.rera_number.presence
      return failure("rera_required", "Add a RERA number on the broker or the firm before creating a visit pass.") if rera.blank?

      pass = reserve(project, when_at, suffix)
      return pass if pass.is_a?(Result)

      finish(pass, project, when_at, suffix, rera)
    end

    private

    attr_reader :lead, :user, :project_id, :tentative_visit_planned

    def mapped_project
      mapping = lead.lead_projects.includes(:project).find { |row| row.project_id.to_s == project_id.to_s }
      project = mapping&.project
      return failure("not_mapped", "Map this project onto the lead before creating a visit pass.") if project.nil?
      return failure("project_withdrawn", "This project was withdrawn by the developer.") if mapping.withdrawn_at.present? || project.archived?
      return failure("not_marketplace", "Visit passes are only for marketplace projects.") unless turbo_project?(project)

      project
    end

    def turbo_project?(project)
      project.external_ref.to_s.match?(TURBO_CODE)
    end

    def parse_time
      raw = tentative_visit_planned.to_s.strip
      return if raw.blank?

      Time.zone.parse(raw)
    rescue ArgumentError
      nil
    end

    def reserve(project, when_at, suffix)
      # with_lock is the same row lock as Lead#lock_for_activity!.
      lead.with_lock do
        existing = lead.lead_visit_passes.where(project:).order(created_at: :desc).first
        case existing&.turbo_status
        when "used"
          return failure("already_tagged", "This client is already tagged to you for this project.")
        when "duplicate"
          return failure(
            "already_registered",
            "This client is already registered with the developer. Contact your RM to get yourself tagged, subject to the builder's policy."
          )
        when "unused"
          return Result.new(ok?: true, status: :ok, pass: existing)
        when "pending"
          existing
        else
          lead.lead_visit_passes.create!(
            firm: lead.firm,
            project:,
            user:,
            phone_suffix: suffix,
            tentative_visit_planned: when_at,
            turbo_status: "pending"
          )
        end
      end
    rescue ActiveRecord::RecordNotUnique
      existing = lead.lead_visit_passes.where(project:).order(created_at: :desc).first
      return failure("invalid", "Could not create the visit pass.") if existing.nil?
      return Result.new(ok?: true, status: :ok, pass: existing) if existing.turbo_status == "unused"
      return failure("already_tagged", "This client is already tagged to you for this project.") if existing.turbo_status == "used"
      if existing.turbo_status == "duplicate"
        return failure(
          "already_registered",
          "This client is already registered with the developer. Contact your RM to get yourself tagged, subject to the builder's policy."
        )
      end

      existing
    end

    def finish(pass, project, when_at, suffix, rera)
      payload = TurboClient.create_visit_pass(request_body(pass, project, when_at, suffix, rera))
      code = payload["pass_code"].to_s
      return failure("invalid", "LaunchIQ did not return a pass code.") if code.blank?

      pass.update!(
        pass_code: code,
        pass_url: payload["pass_url"].presence,
        address: payload["address"].presence,
        rm_name: payload["rm_name"].presence,
        rm_contact: payload["rm_contact"].to_s.gsub(/\D/, "").presence,
        tentative_visit_planned: when_at,
        turbo_status: "unused"
      )
      Result.new(ok?: true, status: :created, pass: pass.reload)
    rescue TurboClient::Error => e
      pass.destroy! if e.status.present? && e.status.to_i < 500 && pass.turbo_status == "pending"
      failure("launchiq_rejected", e.message)
    end

    def request_body(pass, project, when_at, suffix, rera)
      {
        project_code: project.external_ref,
        client_name: lead.name.presence || "Client",
        phone_suffix: suffix,
        tentative_visit_planned: when_at.utc.iso8601,
        idempotency_key: pass.id,
        broker: {
          name: user.name,
          firm_name: user.firm.name,
          firm_code: user.firm.code,
          contact_number: user.mobile.to_s.gsub(/\D/, "").last(10),
          rera_number: rera,
          realtoriq_firm_id: user.firm_id,
          realtoriq_user_id: user.id
        }
      }
    end

    def failure(code, message)
      Result.new(ok?: false, status: :unprocessable_content, error_code: code, error_message: message)
    end
  end
end
