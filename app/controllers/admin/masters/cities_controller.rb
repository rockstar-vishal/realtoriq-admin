# frozen_string_literal: true

module Admin
  module Masters
    class CitiesController < BaseController
      self.master_model = City
      self.master_label = "City"
      self.master_permitted = %i[name state state_code active]
      self.master_columns = [
        { key: :name, label: "City", type: :text, required: true },
        { key: :state, label: "State", type: :text, required: true },
        { key: :state_code, label: "Code", type: :text, hint: "Two letters. Derived from the state if blank." },
        { key: :active, label: "Active", type: :boolean }
      ]

      private

      def scope = City.alphabetical
      def index_path = admin_masters_cities_path
      def finder_column = :slug
      def finder_param = :slug
    end
  end
end
