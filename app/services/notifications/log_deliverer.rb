# frozen_string_literal: true

module Notifications
  # Development and test transport: writes the code where a developer can read
  # it. Refuses to run in production — if configuration ever drifts, failing
  # loudly is far better than silently printing live codes into a log file.
  class LogDeliverer < Deliverer
    def deliver_code(transport:, destination:, code:, purpose:)
      raise DeliveryError, "LogDeliverer must never run in production" if Rails.env.production?

      Rails.logger.info(
        "\n" \
        "  ┌─ one-time code ──────────────────────────────\n" \
        "  │ #{purpose} via #{transport}\n" \
        "  │ to   #{destination}\n" \
        "  │ code #{code}\n" \
        "  └──────────────────────────────────────────────\n"
      )

      true
    end
  end
end
