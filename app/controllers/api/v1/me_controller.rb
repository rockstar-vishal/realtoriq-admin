# frozen_string_literal: true

module Api
  module V1
    # What the app loads at boot: who is signed in, which firm they belong to,
    # and what that firm is entitled to.
    class MeController < AuthenticatedController
      def show
        subscription = current_firm.current_subscription

        render json: {
          user: {
            id: current_user.id,
            name: current_user.name,
            email: current_user.email,
            mobile: current_user.mobile,
            role: current_user.role,
            notification_mode: current_user.notification_mode,
            rera_number: current_user.rera_number
          },
          firm: {
            id: current_firm.id,
            name: current_firm.name,
            legal_name: current_firm.legal_name,
            code: current_firm.code,
            status: current_firm.status,
            rera_number: current_firm.rera_number,
            city: current_firm.city&.name,
            logo_url: logo_url,
            channels_verified: current_firm.fully_verified?
          },
          subscription: subscription && {
            plan: subscription.plan.name,
            status: subscription.status,
            entitled: subscription.entitled?,
            renews_on: subscription.current_period_end,
            amount: subscription.amount
          },
          # Everything the app is allowed to do, resolved server-side so the
          # client never has to reimplement the role rules.
          permissions: {
            manage_firm_settings: current_user.can_manage_firm_settings?,
            verify_contact_channels: current_user.can_manage_firm_settings?
          },
          limits: {
            devices: current_firm.device_limit,
            users: subscription&.plan&.max_users
          }
        }, status: :ok
      end

      private

      def logo_url
        return nil unless current_firm.logo.attached?

        # Stored but unused by the app today — exposed now so the client can
        # start rendering it without a server change.
        url_for(current_firm.logo)
      end
    end
  end
end
