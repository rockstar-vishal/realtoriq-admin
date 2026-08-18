# frozen_string_literal: true

module Admin
  module Masters
    class LeadStatusesController < BaseController
      self.master_model = LeadStatus
      self.master_label = "Lead status"
      self.master_permitted = %i[name code sort_order is_dead is_booked is_terminal active]
      self.master_columns = [
        { key: :name, label: "Status", type: :text, required: true },
        { key: :sort_order, label: "Order", type: :number },
        { key: :is_dead, label: "Counts as dead", type: :boolean,
          hint: "Drives the dead-leads report." },
        { key: :is_booked, label: "Counts as booked", type: :boolean },
        { key: :active, label: "Active", type: :boolean }
      ]

      private

      def scope = LeadStatus.ordered
      def index_path = admin_masters_lead_statuses_path
    end
  end
end
