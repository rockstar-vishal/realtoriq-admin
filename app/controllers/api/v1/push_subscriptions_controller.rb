# frozen_string_literal: true

module Api
  module V1
    class PushSubscriptionsController < AuthenticatedController
      def show
        render json: { push_subscription: { subscribed: subscribed? } }, status: :ok
      end

      def vapid_public_key
        key = ::Notifications::Vapid.public_key
        if key.blank?
          return render_error("push_not_configured",
                              "Browser push is not configured on this server.",
                              status: :service_unavailable)
        end

        render json: { vapid_public_key: key }, status: :ok
      end

      def create
        result = ::Notifications::RegisterPushSubscription.call(
          user: current_user,
          session: current_session,
          endpoint: params[:endpoint],
          p256dh: params[:p256dh],
          auth_key: params[:auth],
          content_encoding: params[:content_encoding],
          user_agent: request.user_agent
        )
        if result.ok?
          render json: { push_subscription: { subscribed: true } }, status: :created
        else
          render_error(result.error_code, result.error_message, status: :unprocessable_content)
        end
      end

      def destroy
        current_session.push_subscriptions.delete_all
        head :no_content
      end

      private

      def subscribed?
        current_session.push_subscriptions.exists?
      end
    end
  end
end
