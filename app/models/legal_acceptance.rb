# frozen_string_literal: true

# What the broker accepted, and the PDF that records it.
#
# firm_id stays nullable. After an activated firm is destroyed the row is kept
# until retain_until, and those rows are read with across_firms.
class LegalAcceptance < ApplicationRecord
  include FirmScoped

  # FirmScoped declares a required firm. Redeclared so a retained row can exist
  # after the firm is gone. Presence is still required when the row is created.
  belongs_to :firm, optional: true
  belongs_to :onboarding_application, optional: true

  has_one_attached :document, dependent: :purge_later

  validates :firm, presence: true, on: :create
  validates :terms_version, :terms_sha256, :privacy_version, :privacy_sha256,
    :statement, :accepted_at, presence: true

  attr_readonly :terms_version, :terms_sha256, :privacy_version, :privacy_sha256,
    :statement, :accepted_at, :ip, :user_agent, :evidence
end
