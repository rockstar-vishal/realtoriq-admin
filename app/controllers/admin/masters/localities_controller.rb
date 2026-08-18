# frozen_string_literal: true

module Admin
  module Masters
    class LocalitiesController < BaseController
      self.master_model = Locality
      self.master_label = "Locality"
      self.master_permitted = %i[name city_id pincode active]
      self.master_columns = [
        { key: :name, label: "Locality", type: :text, required: true },
        { key: :city_id, label: "City", type: :association, collection: -> { City.active.alphabetical },
          display: :display_name, required: true },
        { key: :pincode, label: "Pincode", type: :text },
        { key: :active, label: "Active", type: :boolean }
      ]

      private

      def scope = Locality.includes(:city).alphabetical
      def index_path = admin_masters_localities_path
    end
  end
end
