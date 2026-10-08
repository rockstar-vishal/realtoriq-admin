# frozen_string_literal: true

module Prospects
  # Sends a closed prospect back to the calling list.
  #
  # Not interested only changes status. Interested also deletes the linked
  # lead, and only when that lead has never been worked. Lead#destroy deletes
  # bookings, and a booking deletes its invoices and collections, so the
  # worked-lead check is what keeps money records alive.
  class MoveToFollowing
    WORKED_MESSAGE = "This lead has already been worked, so it was left in place."

    Result = Struct.new(:ok?, :prospect, :error_code, :error_message, keyword_init: true)

    def initialize(prospect:, actor:)
      @prospect = prospect
      @actor = actor
    end

    def call
      result = nil
      Prospect.transaction do
        result = move
        raise ActiveRecord::Rollback unless result.ok?
      end
      result
    end

    private

    attr_reader :prospect, :actor

    def move
      locked = Prospect.lock.find(prospect.id)
      return reopen(locked) if locked.status_not_interested?
      return release_lead(locked) if locked.status_interested?

      Result.new(ok?: false, prospect: locked, error_code: "not_movable",
        error_message: "Only an interested or not interested prospect can move back to Following.")
    end

    def reopen(locked)
      locked.update!(status: "following")
      Result.new(ok?: true, prospect: locked)
    end

    def release_lead(locked)
      unless locked.can_move_to_following?(actor)
        return Result.new(ok?: false, prospect: locked, error_code: "forbidden_role",
          error_message: "Only the lead's assignee or a manager can move this prospect back.")
      end

      lead = locked.lead
      if lead.nil?
        locked.update!(status: "following", lead_id: nil)
        return Result.new(ok?: true, prospect: locked)
      end

      lead.lock!
      if worked?(lead)
        return Result.new(ok?: false, prospect: locked, error_code: "lead_worked",
          error_message: WORKED_MESSAGE)
      end

      locked.update!(status: "following", lead_id: nil)
      lead.destroy!
      Result.new(ok?: true, prospect: locked)
    end

    # Every association here is one Lead#destroy would cascade through, or a
    # foreign key that would raise. Bookings are the one that must never go.
    def worked?(lead)
      lead.lead_followups.exists? ||
        lead.lead_visits.exists? ||
        lead.lead_visit_passes.exists? ||
        lead.bookings.exists? ||
        InboundEnquiry.where(lead_id: lead.id).exists? ||
        MarketplaceEnquiry.where(lead_id: lead.id).exists? ||
        FacebookLeadImport.where(lead_id: lead.id).exists?
    end
  end
end
