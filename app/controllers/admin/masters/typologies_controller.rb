# frozen_string_literal: true

module Admin
  module Masters
    class TypologiesController < BaseController
      self.master_model = Typology
      self.master_label = "Configuration"
      self.master_permitted = %i[name code bedrooms sort_order active category]
      self.master_columns = [
        { key: :name, label: "Configuration", type: :text, required: true },
        { key: :category, label: "Category", type: :select,
          options: [
            [ "Residential", "residential" ],
            [ "Commercial", "commercial" ],
            [ "Plot & Land", "land" ]
          ] },
        { key: :bedrooms, label: "Bedrooms", type: :decimal, hint: "2.5 for a 2.5 BHK." },
        { key: :sort_order, label: "Order", type: :number },
        { key: :active, label: "Active", type: :boolean }
      ]

      before_action :set_record, only: :merge

      def review
        @project_rows = ProjectTypology.where(needs_review: true)
          .includes(:project, :typology)
          .order(:created_at)
        @configurations = Typology.where(needs_review: true).order(:name)
        @targets = Typology.where(merged_into_id: nil).ordered
      end

      def remap
        row = ProjectTypology.find_by(id: params[:project_typology_id])
        target = Typology.where(merged_into_id: nil).find_by(id: params[:typology_id])
        if row.nil? || target.nil?
          redirect_to review_admin_masters_typologies_path, alert: "Choose a configuration."
          return
        end

        original = row.label
        row.typology = target
        row.needs_review = false
        row.review_note = nil
        row.save!
        remember_review_alias(original, target)
        redirect_to review_admin_masters_typologies_path, notice: "Configuration updated."
      rescue ActiveRecord::RecordInvalid => e
        redirect_to review_admin_masters_typologies_path, alert: e.record.errors.full_messages.to_sentence
      end

      def merge
        target = Typology.where(merged_into_id: nil).where.not(id: @record.id).find_by(id: params[:target_id])
        if target.nil?
          redirect_to review_admin_masters_typologies_path, alert: "Choose a configuration to merge into."
          return
        end

        @record.merge_into!(target, admin: current_admin)
        redirect_to review_admin_masters_typologies_path, notice: "Merged #{@record.name} into #{target.name}."
      rescue ActiveRecord::RecordInvalid => e
        redirect_to review_admin_masters_typologies_path, alert: e.record.errors.full_messages.to_sentence
      end

      private

      def scope = Typology.ordered
      def index_path = admin_masters_typologies_path

      def remember_review_alias(label, target)
        return if label.blank? || Typology.generic_name?(label)

        alias_row = ConfigurationAlias.find_or_initialize_by(key: Realtoriq::NameKey.call(label))
        alias_row.update!(typology: target, source: "review", created_by_admin: current_admin)
      end
    end
  end
end
