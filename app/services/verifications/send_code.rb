# frozen_string_literal: true

module Verifications
  # Issues a verification code for one of a firm's contact channels and hands it
  # to the right transport.
  #
  # Used by both surfaces: ops clicking "Send code" in the admin panel, and the
  # firm's super_admin doing the same from the broker app.
  class SendCode
    Result = Struct.new(:ok?, :error, :channel, keyword_init: true)

    def initialize(channel:, ip: nil)
      @channel = channel
      @ip = ip
    end

    def call
      return failure("Wait a moment before sending another code.") if channel.resend_throttled?
      return failure("This channel is already verified.") if channel.verified?

      _record, plaintext = OneTimeCode.issue!(
        purpose: "verify_#{channel.kind}",
        destination: channel.value,
        contact_channel: channel,
        ip: @ip
      )

      deliver(plaintext)

      channel.update!(verification_state: :pending, last_code_sent_at: Time.current)

      Result.new(ok?: true, channel:)
    rescue Notifications::Deliverer::DeliveryError => e
      # The code row is left behind deliberately: it is harmless, and deleting
      # it would let a caller hammer the provider by retrying a failing send.
      Rails.logger.warn("[verification] delivery failed for channel #{channel.id}: #{e.message}")
      failure("Couldn't send the code right now. Try again shortly.")
    end

    private

    attr_reader :channel

    def deliver(plaintext)
      Notifications::Deliverer.current.deliver_code(
        transport: channel.delivery_transport,
        destination: channel.value,
        code: plaintext,
        purpose: "verify_#{channel.kind}"
      )
    end

    def failure(message) = Result.new(ok?: false, error: message, channel:)
  end
end
