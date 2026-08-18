# frozen_string_literal: true

module Admin
  module Masters
    class BuildersController < BaseController
      self.master_model = Builder
      self.master_label = "Builder"
      self.master_permitted = %i[name website active]
      self.master_columns = [
        { key: :name, label: "Builder", type: :text, required: true },
        { key: :website, label: "Website", type: :text },
        { key: :active, label: "Active", type: :boolean }
      ]

      private

      # Only the platform's own list. Builders a broker added inline belong to
      # that firm and are not ops' to edit from here.
      def scope = Builder.global.alphabetical

      def index_path = admin_masters_builders_path

      # By id, not slug: two firms can now hold the same slug, so a slug no
      # longer identifies a single row.
      def finder_column = :id
      def finder_param = :id
    end
  end
end
