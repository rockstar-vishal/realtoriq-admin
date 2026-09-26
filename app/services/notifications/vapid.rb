# frozen_string_literal: true

module Notifications
  # One keypair for every environment, stored in Rails credentials under :vapid
  # (`public_key`, `private_key`, optional `subject`). The browser binds the
  # public key into the subscription, so a second copy in the frontend env will
  # drift and every send will come back 401.
  #
  # Generate a pair with `bin/rails notifications:generate_vapid` and paste it
  # into credentials. Do not commit the private key. Rotating the pair
  # invalidates every stored subscription.
  class Vapid
    def self.public_key
      Rails.application.credentials.dig(:vapid, :public_key).presence
    end

    def self.private_key
      Rails.application.credentials.dig(:vapid, :private_key).presence
    end

    def self.subject
      Rails.application.credentials.dig(:vapid, :subject).presence || "mailto:noreply@realtoriq.app"
    end

    def self.configured?
      public_key.present? && private_key.present?
    end
  end
end
