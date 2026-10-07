# frozen_string_literal: true

module Api
  module V1
    module Facebook
      class FormsController < BaseController
        def create
          page = current_firm.facebook_pages.find_by(id: params[:id])
          return not_found if page.nil?

          meta_form_id = params[:meta_form_id].to_s
          entry = page.catalog_entry_for(meta_form_id)
          if entry.blank?
            return render_error("not_found", "Form not found. Sync forms and try again.", status: :not_found)
          end

          existing = FacebookLeadForm.across_firms.find_by(form_id: meta_form_id)
          if existing
            if existing.firm_id == current_firm.id
              return render json: { form: form_json(existing) }
            end

            return render_error("already_mapped", "This form is already mapped to another firm.",
              status: :unprocessable_entity)
          end

          form = FacebookLeadForm.create!(
            firm: current_firm,
            facebook_page: page,
            form_id: meta_form_id,
            form_name: entry["form_name"].presence || "Form #{meta_form_id}",
            questions: ::Facebook::FieldMapper.normalize_questions(entry["questions"]),
            meta_status: entry["status"],
            active: entry["status"].to_s.upcase == "ACTIVE"
          )
          render json: { form: form_json(form) }, status: :created
        rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid
          render_error("already_mapped", "This form is already mapped to another firm.", status: :unprocessable_entity)
        end

        def show
          form = current_firm.facebook_lead_forms.find_by(id: params[:id])
          return not_found if form.nil?

          render json: { form: form_json(form) }
        end

        def update
          form = current_firm.facebook_lead_forms.find_by(id: params[:id])
          return not_found if form.nil?

          assign_form(form)
          problem = form.save_error
          if problem
            return render_error("invalid_form", problem, status: :unprocessable_entity)
          end
          unless form.save
            return render_error("invalid_form", form.errors.full_messages.to_sentence, status: :unprocessable_entity)
          end

          AuditEvent.record!(subject: form, action: "facebook.form.update", actor: current_user, firm: current_firm)
          render json: { form: form_json(form) }
        end

        private

        def assign_form(form)
          if params.key?(:active)
            form.active = ActiveModel::Type::Boolean.new.cast(params[:active])
          end
          if params.key?(:field_mappings)
            form.field_mappings = ::Facebook::FieldMapper.sanitize_mappings(params[:field_mappings])
          end
          if params[:project_id].present? && params[:property_id].present?
            form.project_id = params[:project_id]
            form.property_id = params[:property_id]
            return
          end
          if params.key?(:project_id)
            form.project_id = params[:project_id].presence
            form.property_id = nil if form.project_id.present?
          end
          if params.key?(:property_id)
            form.property_id = params[:property_id].presence
            form.project_id = nil if form.property_id.present?
          end
          form.assigned_user_id = params[:assigned_user_id].presence if params.key?(:assigned_user_id)
          form.lead_source_id = params[:lead_source_id].presence if params.key?(:lead_source_id)
        end

        def form_json(form)
          sample = ::Facebook::FieldMapper.synthetic_preview(mappings: form.field_mappings, questions: form.questions)
          {
            "id" => form.id,
            "form_id" => form.form_id,
            "form_name" => form.form_name,
            "active" => form.active,
            "questions" => form.questions_list,
            "ui_field_mappings" => form.ui_field_mappings,
            "target_options" => ::Facebook::FieldMapper::TARGET_OPTIONS,
            "project_id" => form.project_id,
            "property_id" => form.property_id,
            "listing_name" => form.listing_name,
            "assigned_user_id" => form.assigned_user_id,
            "lead_source_id" => form.lead_source_id,
            "explicit_mappings" => form.explicit_mappings?,
            "ready_for_import_error" => form.ready_for_import_error,
            "sample" => {
              "name" => sample.name,
              "mobile" => sample.mobile,
              "alt_mobile" => sample.alt_mobile,
              "email" => sample.email,
              "notes" => sample.notes
            }
          }
        end
      end
    end
  end
end
