# frozen_string_literal: true

module Admin
  module Masters
    class PropertyTypesController < BaseController
      self.master_model = PropertyType
      self.master_label = "Property type"
      self.master_permitted = %i[name code sort_order active]
      self.master_columns = [
        { key: :name, label: "Property type", type: :text, required: true },
        { key: :sort_order, label: "Order", type: :number },
        { key: :active, label: "Active", type: :boolean }
      ]

      private

      def scope = PropertyType.ordered
      def index_path = admin_masters_property_types_path
    end
  end
end
