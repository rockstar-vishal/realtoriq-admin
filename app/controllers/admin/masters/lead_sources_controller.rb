# frozen_string_literal: true

module Admin
  module Masters
    class LeadSourcesController < BaseController
      self.master_model = LeadSource
      self.master_label = "Lead source"
      self.master_permitted = %i[name code category sort_order active]
      self.master_columns = [
        { key: :name, label: "Source", type: :text, required: true },
        { key: :category, label: "Category", type: :select, options: LeadSource::CATEGORIES,
          hint: "Groups the portals together in the source report." },
        { key: :sort_order, label: "Order", type: :number },
        { key: :active, label: "Active", type: :boolean }
      ]

      private

      def scope = LeadSource.ordered
      def index_path = admin_masters_lead_sources_path
    end
  end
end
