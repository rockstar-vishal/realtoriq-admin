# frozen_string_literal: true

# A website's enquiry id, stored only after the lead is saved. A repeat of
# the same id does nothing, and a failed call can be retried because this
# row was never written.
class InboundEnquiry < ApplicationRecord
  include FirmScoped

  CHANNELS = %w[99acres magicbricks housing general].freeze

  belongs_to :lead, -> { unscope(where: :firm_id) }
  belongs_to_same_firm :lead

  validates :channel, inclusion: { in: CHANNELS }
  validates :external_id, presence: true
  validates :external_id, uniqueness: { scope: %i[firm_id channel] }
end
