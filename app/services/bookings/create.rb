# frozen_string_literal: true

module Bookings
  # A booking always hangs off a lead — the design's flow starts by finding one
  # by phone, and says so: "every booking is tied to a lead record".
  #
  # The lead's status moves only when the caller sends `mark_lead_booked`, and
  # then through Leads::TransitionStatus so the timeline matches a manual
  # change. Cancelling a booking still leaves the lead alone.
  class Create
    Result = Struct.new(:ok?, :booking, :errors, :error_code, :error_message, :details,
                        :lead_status_unchanged, :property_status_unchanged, keyword_init: true)

    MAX_CODE_ATTEMPTS = 5
    UNIT_INDEX = "index_bookings_on_live_project_unit"

    def initialize(firm:, actor:, lead:, attributes:, use_existing: false, new_name: nil,
      mark_lead_booked: false, mark_property_booked: false)
      @firm = firm
      @actor = actor
      @lead = lead
      @attributes = attributes
      @use_existing = ActiveModel::Type::Boolean.new.cast(use_existing)
      @new_name = new_name
      @mark_lead_booked = ActiveModel::Type::Boolean.new.cast(mark_lead_booked)
      @mark_property_booked = ActiveModel::Type::Boolean.new.cast(mark_property_booked)
    end

    def call
      copy_error = nil
      booking = nil
      attempts = 0
      lead_status_unchanged = false
      property_status_unchanged = false
      status_error = nil
      link_error = nil

      begin
        Booking.transaction do
          copy = catalog_copy_result
          if copy && !copy.ok?
            copy_error = copy
            raise ActiveRecord::Rollback
          end

          lead.lock_for_activity!
          booking = build
          self.class.apply_copy(booking, copy, attributes[:project_id])
          link_error = booking.link_problem
          raise ActiveRecord::Rollback if link_error

          booking.save!
          status_error, lead_status_unchanged = apply_booked_status(booking)
          raise ActiveRecord::Rollback if status_error

          property_status_unchanged = property_left_as_it_was?(booking)
        end
      rescue ActiveRecord::RecordNotUnique => e
        if e.message.include?(UNIT_INDEX)
          booking ||= build
          return unit_taken(booking)
        end
        if e.message.include?(Booking::LIVE_LISTING_INDEX)
          booking ||= build
          return listing_taken(booking)
        end

        attempts += 1
        raise if attempts >= MAX_CODE_ATTEMPTS

        # Clear it so assign_code takes the next number rather than re-sending
        # the one that just collided.
        booking.code = nil
        retry
      end

      return status_failure(status_error) if status_error
      return copy_failure(copy_error) if copy_error
      return link_failure(link_error) if link_error

      Result.new(ok?: true, booking:, lead_status_unchanged:, property_status_unchanged:)
    rescue ActiveRecord::RecordInvalid => e
      record = e.record
      return unit_taken(record) if record.errors.of_kind?(:unit_no, :taken)
      return link_failure(record.link_problem) if record.is_a?(Booking) && record.link_problem

      Result.new(ok?: false, booking: record, errors: record.errors)
    end

    private

    attr_reader :firm, :actor, :lead, :attributes, :use_existing, :new_name,
      :mark_lead_booked, :mark_property_booked

    def self.copy_catalog(project_id:, use_existing: false, new_name: nil)
      project_id = project_id.presence
      return if project_id.blank?

      project = Project.find_by(id: project_id)
      project ||= Project.unscoped.find_by(id: project_id, firm_id: nil, source: "catalog")
      return if project.nil? || project.from_own?

      Inventory::CopyCatalogProject.new(
        catalog: project,
        use_existing: ActiveModel::Type::Boolean.new.cast(use_existing),
        new_name:
      ).call
    end

    # A catalog or marketplace id is replaced by the firm's copy. A configuration
    # id sent for the source row moves with it, matched on typology and label.
    # When the copy has no such row, the booking keeps the snapshot from the
    # source and stores no pointer, so the broker is not blocked.
    def self.apply_copy(booking, copy, source_project_id)
      return unless copy

      booking.project = copy.project
      sent_id = booking.project_typology_id
      return if sent_id.blank?

      source = ProjectTypology.find_by(id: sent_id)
      return unless source && source.project_id.to_s == source_project_id.to_s

      mapped = ConfigurationMap.call(
        typology_id: sent_id,
        source_project_id:,
        project: copy.project
      )
      if mapped
        booking.project_typology_id = mapped
      else
        booking.project_typology_id = nil
        booking.typology_id = source.typology_id
        booking.configuration_label = source.label
      end
    end

    def catalog_copy_result
      self.class.copy_catalog(
        project_id: attributes[:project_id], use_existing:, new_name:
      )
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

    # Asked to mark the listing, and it was not an own Available one.
    def property_left_as_it_was?(booking)
      return false unless mark_property_booked

      !ListingStatus.mark_booked!(booking, actor)
    end

    def listing_taken(booking)
      other = booking.conflicting_live_listing
      link_failure(
        {
          code: "listing_already_booked",
          message: "This listing already has a live booking.",
          details: { booking_id: other&.id, code: other&.code }
        }
      )
    end

    def link_failure(problem)
      Result.new(
        ok?: false, error_code: problem[:code], error_message: problem[:message],
        details: problem[:details]
      )
    end

    def unit_taken(booking)
      Result.new(
        ok?: false, booking:, error_code: "unit_taken",
        error_message: "That unit is already booked on this project.",
        details: { project_id: booking.project_id, unit_no: booking.unit_no }
      )
    end

    # Missing booked status is not a failure: the booking is the record the
    # broker asked for, and the response says the lead was left as it was.
    def apply_booked_status(booking)
      return [ nil, false ] unless mark_lead_booked

      status = LeadStatus.active.booked.ordered.first
      return [ nil, true ] if status.nil?

      # The day the unit was booked, not the day the row was typed in.
      booked_at = booking.booked_on.in_time_zone(Lead::NCD_ZONE).beginning_of_day
      result = Leads::TransitionStatus.new(lead:, to_status: status, actor:, booked_at:).call
      result.ok? ? [ nil, false ] : [ result, false ]
    end

    def status_failure(result)
      Result.new(
        ok?: false, error_code: result.error_code, error_message: result.error_message,
        details: result.error_details
      )
    end

    def copy_failure(copy)
      Result.new(ok?: false, error_code: copy.error_code, error_message: copy.error_message,
                 details: copy.details)
    end
  end
end
