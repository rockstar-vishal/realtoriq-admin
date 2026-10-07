# frozen_string_literal: true

module Api
  module V1
    module LeadVisitPassSerializer
      module_function

      def call(pass)
        {
          id: pass.id,
          pass_code: pass.pass_code,
          pass_url: pass.pass_url,
          project_id: pass.project_id,
          project_name: pass.project&.name,
          address: pass.address,
          rm_name: pass.rm_name,
          rm_contact: pass.rm_contact,
          status_message: pass.status_message,
          phone_suffix: pass.phone_suffix,
          tentative_visit_planned: pass.tentative_visit_planned,
          turbo_status: pass.turbo_status,
          turbo_lead_code: pass.turbo_lead_code,
          turbo_status_name: pass.turbo_status_name,
          status_detail: pass.status_detail,
          last_followup_at: pass.last_followup_at,
          last_followup_comment: pass.last_followup_comment,
          next_followup_at: pass.next_followup_at,
          last_fetched_at: pass.last_fetched_at,
          next_refresh_at: pass.next_refresh_at
        }
      end
    end
  end
end
