# frozen_string_literal: true

module Api
  module V1
    module NotificationSerializer
      def self.call(notification)
        {
          id: notification.id,
          kind: notification.kind,
          title: notification.title,
          body: notification.body,
          read_at: notification.read_at,
          data: notification.data,
          created_at: notification.created_at
        }
      end
    end
  end
end
