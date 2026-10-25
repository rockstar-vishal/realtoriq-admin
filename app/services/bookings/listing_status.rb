# frozen_string_literal: true

module Bookings
  # Moves a firm's own listing when a booking asks it to. A marketplace
  # listing, or one that is not Available, is left alone. The old listing is
  # never touched when the booking later points somewhere else.
  module ListingStatus
    module_function

    def mark_booked!(booking, actor)
      listing = Property.unscoped.lock.find_by(id: booking.property_id)
      return false unless listing&.firm_id == booking.firm_id && listing.available?

      from = listing.status
      # Status only, same as Booking#cancel!. update! would re-run every
      # Property validation and refuse an older listing.
      listing.status = "booked"
      listing.save!(validate: false)
      record_status(listing, actor, from:, to: "booked", booking:)
      booking.association(:property).reset
      true
    end

    # The booking being cancelled is already out of the live set, or is
    # excluded here. Another live booking of this firm keeps the listing booked.
    def release!(booking, actor)
      listing = Property.unscoped.lock.find_by(id: booking.property_id)
      return unless listing&.firm_id == booking.firm_id && listing.booked?
      return if booking.other_live_listing_booking

      from = listing.status
      listing.status = "available"
      listing.save!(validate: false)
      record_status(listing, actor, from:, to: "available", booking:)
      booking.association(:property).reset
    end

    def record_status(listing, actor, from:, to:, booking:)
      AuditEvent.record!(
        subject: listing,
        firm: listing.firm,
        actor:,
        action: "property.status_changed",
        metadata: { "from" => from, "to" => to, "booking_id" => booking.id }
      )
    end
  end
end
