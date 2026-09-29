# frozen_string_literal: true

# One buyer submission of one microsite form. The same enquiry_id again is a
# no-op, so a buyer who taps Send twice does not get a second lead.
class MarketplaceEnquiry < ApplicationRecord
  include FirmScoped

  OUTCOMES = %w[created existing].freeze

  belongs_to :project_share_link, -> { unscope(where: :firm_id) }
  belongs_to :lead, -> { unscope(where: :firm_id) }, optional: true

  belongs_to_same_firm :project_share_link, :lead

  validates :enquiry_id, presence: true, uniqueness: true
  validates :outcome, inclusion: { in: OUTCOMES }, allow_nil: true
end
