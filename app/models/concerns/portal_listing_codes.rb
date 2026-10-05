# frozen_string_literal: true

# Codes a portal already uses for this listing. Saved from a small dialog on
# the show page, never from the create or edit form, so those screens stay
# short. Blank becomes nil so the unique index does not treat "" as a code.
module PortalListingCodes
  extend ActiveSupport::Concern

  COLUMNS = {
    "99acres" => "portal_99acres_code",
    "magicbricks" => "portal_magicbricks_code",
    "housing" => "portal_housing_code"
  }.freeze

  included do
    before_validation :normalise_portal_codes

    validate :portal_99acres_code_is_unique
    validate :portal_magicbricks_code_is_unique
    validate :portal_housing_code_is_unique
  end

  def portal_codes_payload
    {
      "99acres" => portal_99acres_code,
      "magicbricks" => portal_magicbricks_code,
      "housing" => portal_housing_code
    }
  end

  def assign_portal_codes(codes)
    self.portal_99acres_code = codes["99acres"] if codes.key?("99acres")
    self.portal_magicbricks_code = codes["magicbricks"] if codes.key?("magicbricks")
    self.portal_housing_code = codes["housing"] if codes.key?("housing")
    save!
  end

  private

  def normalise_portal_codes
    self.portal_99acres_code = self.class.normalise_portal_code(portal_99acres_code)
    self.portal_magicbricks_code = self.class.normalise_portal_code(portal_magicbricks_code)
    self.portal_housing_code = self.class.normalise_portal_code(portal_housing_code)
  end

  def portal_99acres_code_is_unique
    portal_code_taken("99acres", portal_99acres_code) do |scope, value|
      scope.where("lower(portal_99acres_code) = ?", value.downcase)
    end
  end

  def portal_magicbricks_code_is_unique
    portal_code_taken("magicbricks", portal_magicbricks_code) do |scope, value|
      scope.where("lower(portal_magicbricks_code) = ?", value.downcase)
    end
  end

  def portal_housing_code_is_unique
    portal_code_taken("housing", portal_housing_code) do |scope, value|
      scope.where("lower(portal_housing_code) = ?", value.downcase)
    end
  end

  def portal_code_taken(portal, value)
    return if value.blank?
    return if respond_to?(:marketplace?) && marketplace?

    clash = self.class.unscoped.where(firm_id:)
    clash = clash.where.not(id:) if id.present?
    return unless yield(clash, value).exists?

    errors.add(:base, "That #{portal} code is already saved on another #{model_name.human.downcase}.")
  end

  class_methods do
    def normalise_portal_code(value)
      value.to_s.strip.gsub(/\s+/, " ").presence
    end
  end
end
