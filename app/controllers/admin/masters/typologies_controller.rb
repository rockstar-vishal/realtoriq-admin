# frozen_string_literal: true

module Admin
  module Masters
    class TypologiesController < BaseController
      self.master_model = Typology
      self.master_label = "Typology"
      self.master_permitted = %i[name code bedrooms sort_order active]
      self.master_columns = [
        { key: :name, label: "Typology", type: :text, required: true },
        { key: :bedrooms, label: "Bedrooms", type: :decimal, hint: "2.5 for a 2.5 BHK." },
        { key: :sort_order, label: "Order", type: :number },
        { key: :active, label: "Active", type: :boolean }
      ]

      private

      def scope = Typology.ordered
      def index_path = admin_masters_typologies_path
    end
  end
end
