# frozen_string_literal: true

# Platform staff — the people who run the admin panel.
#
# Separate from User (brokers) on purpose: brokers authenticate with a one-time
# code to their mobile and have no password at all, so there is no shared
# credential path between the two and no way to escalate from one to the other.
class AdminUser < ApplicationRecord
  has_secure_password

  has_many :admin_sessions, dependent: :destroy

  validates :name, presence: true
  validates :email, presence: true, uniqueness: { case_sensitive: false },
    format: { with: URI::MailTo::EMAIL_REGEXP }
  validates :password, length: { minimum: 12 }, allow_nil: true

  normalizes :email, with: ->(email) { email.to_s.downcase.strip }

  scope :active, -> { where(active: true) }

  def self.authenticate(email:, password:)
    active.find_by(email: email.to_s.downcase.strip)&.authenticate(password) || nil
  end

  def display_name = name.presence || email
end
