# frozen_string_literal: true

# A random global code for a project (P-) or a property (H-). Not a sequence:
# a shared marketplace row cannot take a per-firm number, and a sequence would
# tell another firm how many listings exist.
#
# The alphabet skips I, O, 0 and 1 so a code read off a screen is harder to
# mistype. Matching elsewhere is case-insensitive; stored values are uppercase.
module InventoryCode
  extend ActiveSupport::Concern

  ALPHABET = (("A".."Z").to_a - %w[I O] + ("2".."9").to_a).freeze
  BODY = "[#{ALPHABET.join}]{6}"
  MAX_ATTEMPTS = 5

  included do
    class_attribute :inventory_code_prefix, instance_accessor: false
    class_attribute :inventory_code_index, instance_accessor: false

    before_validation :assign_inventory_code, on: :create
    validates :code, presence: true
    validate :inventory_code_matches_pattern
  end

  class_methods do
    def inventory_code_format
      /\A#{inventory_code_prefix}-#{BODY}\z/
    end

    def generate_inventory_code
      "#{inventory_code_prefix}-#{Array.new(6) { ALPHABET.sample }.join}"
    end
  end

  private

  def assign_inventory_code
    self.code = code.to_s.strip.upcase.presence || self.class.generate_inventory_code
  end

  def inventory_code_matches_pattern
    return if code.blank? || code.match?(self.class.inventory_code_format)

    errors.add(:code, "is not a valid #{self.class.inventory_code_prefix}- code")
  end

  # save! calls create_or_update, not save. A collision has to be retried
  # inside a savepoint: IngestProject and CopyCatalogProject rescue
  # RecordNotUnique for a different constraint, and a unique violation aborts
  # the surrounding transaction unless this one is nested.
  def create_or_update(**)
    attempts = 0
    begin
      self.class.transaction(requires_new: true) { super }
    rescue ActiveRecord::RecordNotUnique => e
      raise unless new_record? && inventory_code_collision?(e)

      attempts += 1
      raise if attempts >= MAX_ATTEMPTS

      self.code = self.class.generate_inventory_code
      retry
    end
  end

  def inventory_code_collision?(error)
    error.message.include?(self.class.inventory_code_index)
  end
end
