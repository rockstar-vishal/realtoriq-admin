# frozen_string_literal: true

# The human timeline on a lead — what the broker did, and when they did it.
#
# `status_change` rows are written by Leads::TransitionStatus so the timeline
# reads continuously, and are rejected from the API: pipeline movement happens
# through the status endpoint, which also writes the reporting record.
class LeadActivity < ApplicationRecord
  include FirmScoped

  KINDS = %w[call whatsapp visit note status_change].freeze
  LOGGABLE_KINDS = (KINDS - %w[status_change]).freeze

  enum :kind, KINDS.index_by(&:itself), validate: true

  # Unscoped for the reason documented on Lead: reached through a lead that
  # has already passed the tenant check.
  belongs_to :lead, -> { unscope(where: :firm_id) }
  belongs_to :user, -> { unscope(where: :firm_id) }, optional: true

  validates :occurred_at, presence: true
  validates :body, presence: true, unless: :status_change?

  before_validation :default_occurred_at, on: :create

  scope :recent_first, -> { order(occurred_at: :desc, created_at: :desc) }

  private

  def default_occurred_at
    self.occurred_at ||= Time.current
  end
end
