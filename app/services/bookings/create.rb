# frozen_string_literal: true

module Bookings
  # A booking always hangs off a lead — the design's flow starts by finding one
  # by phone, and says so: "every booking is tied to a lead record".
  #
  # Deliberately does NOT touch the lead's status. Creating and cancelling both
  # leave it alone, so Booked is set by hand.
  class Create
    Result = Struct.new(:ok?, :booking, :errors, keyword_init: true)

    MAX_CODE_ATTEMPTS = 5

    def initialize(firm:, actor:, lead:, attributes:)
      @firm = firm
      @actor = actor
      @lead = lead
      @attributes = attributes
    end

    def call
      booking = build
      attempts = 0

      begin
        booking.save!
      rescue ActiveRecord::RecordNotUnique
        attempts += 1
        raise if attempts >= MAX_CODE_ATTEMPTS

        # Clear it so assign_code takes the next number rather than re-sending
        # the one that just collided.
        booking.code = nil
        retry
      end

      Result.new(ok?: true, booking:)
    rescue ActiveRecord::RecordInvalid => e
      Result.new(ok?: false, booking: e.record, errors: e.record.errors)
    end

    private

    attr_reader :firm, :actor, :lead, :attributes

    def build
      booking = Booking.new(attributes)
      booking.firm = firm
      booking.lead = lead
      booking.created_by_user = actor

      # Snapshots: correcting the lead's name later must not rewrite what was
      # booked. Whatever the form sent wins, since the broker may be recording
      # the buyer rather than the enquirer.
      booking.customer_name = attributes[:customer_name].presence || lead.name
      booking.customer_mobile = Phone.normalise(
        attributes[:customer_mobile].presence || lead.mobile
      )
      booking.booked_on ||= Date.current

      booking
    end
  end
end
