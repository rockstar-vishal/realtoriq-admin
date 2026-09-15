# frozen_string_literal: true

module Bookings
  # A booking always hangs off a lead — the design's flow starts by finding one
  # by phone, and says so: "every booking is tied to a lead record".
  #
  # Deliberately does NOT touch the lead's status. Creating and cancelling both
  # leave it alone, so Booked is set by hand.
  class Create
    Result = Struct.new(:ok?, :booking, :errors, :error_code, :error_message, :details,
                        keyword_init: true)

    MAX_CODE_ATTEMPTS = 5
    UNIT_INDEX = "index_bookings_on_live_project_unit"

    def initialize(firm:, actor:, lead:, attributes:, use_existing: false, new_name: nil)
      @firm = firm
      @actor = actor
      @lead = lead
      @attributes = attributes
      @use_existing = ActiveModel::Type::Boolean.new.cast(use_existing)
      @new_name = new_name
    end

    def call
      copy_error = nil
      booking = nil
      attempts = 0

      begin
        Booking.transaction do
          copy = catalog_copy_result
          if copy && !copy.ok?
            copy_error = copy
            raise ActiveRecord::Rollback
          end

          booking = build
          booking.project = copy.project if copy
          booking.save!
        end
      rescue ActiveRecord::RecordNotUnique => e
        if e.message.include?(UNIT_INDEX)
          booking ||= build
          return unit_taken(booking)
        end

        attempts += 1
        raise if attempts >= MAX_CODE_ATTEMPTS

        # Clear it so assign_code takes the next number rather than re-sending
        # the one that just collided.
        booking.code = nil
        retry
      end

      return copy_failure(copy_error) if copy_error

      Result.new(ok?: true, booking:)
    rescue ActiveRecord::RecordInvalid => e
      record = e.record
      return unit_taken(record) if record.errors.of_kind?(:unit_no, :taken)

      Result.new(ok?: false, booking: record, errors: record.errors)
    end

    private

    attr_reader :firm, :actor, :lead, :attributes, :use_existing, :new_name

    def catalog_copy_result
      project = Project.find_by(id: attributes[:project_id])
      return if project.nil? || project.from_own?

      Inventory::CopyCatalogProject.new(catalog: project, use_existing:, new_name:).call
    end

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

    def unit_taken(booking)
      Result.new(
        ok?: false, booking:, error_code: "unit_taken",
        error_message: "That unit is already booked on this project.",
        details: { project_id: booking.project_id, unit_no: booking.unit_no }
      )
    end

    def copy_failure(copy)
      Result.new(ok?: false, error_code: copy.error_code, error_message: copy.error_message,
                 details: copy.details)
    end
  end
end
