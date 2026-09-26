# frozen_string_literal: true

module Api
  module V1
    class NotificationsController < AuthenticatedController
      def index
        @pagy, records = pagy(current_user.notifications.recent_first, limit: 25)
        render json: {
          notifications: records.map { |notification| NotificationSerializer.call(notification) },
          meta: pagination_meta(@pagy).merge(unread_count: current_user.notifications.unread.count)
        }, status: :ok
      end

      def unread_count
        render json: { unread_count: current_user.notifications.unread.count }, status: :ok
      end

      def read
        notification = current_user.notifications.find(params[:id])
        notification.update!(read_at: Time.current) if notification.read_at.nil?
        render json: { notification: NotificationSerializer.call(notification) }, status: :ok
      end

      def mark_all_read
        current_user.notifications.unread.update_all(read_at: Time.current)
        render json: { unread_count: 0 }, status: :ok
      end

      def test
        result = ::Notifications::SendTest.for_session(user: current_user, session: current_session)
        if result.ok?
          render json: test_payload(result), status: :created
        else
          status = result.error_code == "push_not_configured" ? :service_unavailable : :unprocessable_content
          render_error(result.error_code, result.error_message, status:, details: push_details(result))
        end
      end

      private

      def test_payload(result)
        {
          notification: result.notification && NotificationSerializer.call(result.notification),
          push: push_details(result)
        }
      end

      def push_details(result)
        {
          attempted: result.deliveries.size,
          accepted: result.accepted_count,
          results: result.deliveries.map { |delivery| delivery.slice(:status, :code).compact }
        }
      end
    end
  end
end
