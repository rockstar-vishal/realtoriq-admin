# frozen_string_literal: true

# The design's four document slots on a booking.
class BookingDocument < ApplicationRecord
  include FirmScoped

  SLOTS = %w[application_form tagging_confirmation lead_source_proof other].freeze
  # Only "Others" may hold more than one file; the named slots are one each.
  REPEATABLE_SLOTS = %w[other].freeze

  enum :slot, SLOTS.index_by(&:itself), validate: true

  belongs_to :booking, -> { unscope(where: :firm_id) }
  belongs_to :uploaded_by_user, -> { unscope(where: :firm_id) },
    class_name: "User", optional: true

  has_one_attached :file

  validate :file_is_attached

  def self.slot_labels
    { "application_form" => "Application form",
      "tagging_confirmation" => "Tagging confirmation",
      "lead_source_proof" => "Lead source proof",
      "other" => "Others" }
  end

  def display_label = label.presence || self.class.slot_labels[slot]

  private

  def file_is_attached
    errors.add(:file, "is required") unless file.attached?
  end
end
