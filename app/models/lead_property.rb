# frozen_string_literal: true

# A resale or rental listing this lead is considering. Same rules as
# LeadProject: many mappings, kept after a booking, not required to book.
class LeadProperty < ApplicationRecord
  include FirmScoped

  belongs_to :lead, -> { unscope(where: :firm_id) }
  belongs_to :property, -> { unscope(where: :firm_id) }

  belongs_to_same_firm :lead
  validate :property_is_mappable

  validates :property_id, uniqueness: { scope: :lead_id }

  private

  # Same-firm listings map as before. Another firm's listing maps only while
  # that firm is active and the listing is shared and available, and only when
  # sale/rent agrees with the lead.
  def property_is_mappable
    return if property.blank? || lead.blank?

    # Same gate as the marketplace directory: another firm's listing maps only
    # while that firm is active and the listing is shared and available.
    if property.firm_id != firm_id && !shared_from_active_firm?
      errors.add(:property_id, "isn't one of this firm's records")
      return
    end

    return if lead.transaction_type == property.listing_for

    errors.add(:base, "A #{lead.transaction_type} lead cannot be mapped to a #{property.listing_for} listing")
  end

  def shared_from_active_firm?
    property.listed_on_marketplace? && property.available? && property.firm&.active?
  end
end
