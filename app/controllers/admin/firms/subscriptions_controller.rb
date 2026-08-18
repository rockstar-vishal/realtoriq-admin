# frozen_string_literal: true

module Admin
  module Firms
    # Ops-managed billing actions for one firm.
    class SubscriptionsController < Admin::BaseController
      before_action :set_firm

      def create
        plan = Plan.active.find(params.require(:plan_id))
        starts_on = params[:starts_on].presence&.to_date || Date.current

        Subscription.switch_plan!(firm: @firm, plan:, actor: current_admin, starts_on:)

        redirect_to admin_firm_path(@firm, tab: "subscription"), notice: "Now on #{plan.name}."
      end

      def renew
        subscription = @firm.subscriptions.find(params[:id])
        subscription.renew!(actor: current_admin)

        redirect_to admin_firm_path(@firm, tab: "subscription"),
          notice: "Renewed to #{subscription.current_period_end.strftime('%d %b %Y')}."
      end

      def cancel
        subscription = @firm.subscriptions.find(params[:id])
        reason = params[:cancel_reason].to_s.strip

        if reason.blank?
          redirect_to admin_firm_path(@firm, tab: "subscription"), alert: "A cancellation needs a reason."
          return
        end

        subscription.cancel!(reason:, actor: current_admin)

        redirect_to admin_firm_path(@firm, tab: "subscription"), notice: "Subscription cancelled."
      end

      private

      def set_firm
        @firm = Firm.find_by!(slug: params[:firm_slug])
      end
    end
  end
end
