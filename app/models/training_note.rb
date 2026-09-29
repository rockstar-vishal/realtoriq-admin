# frozen_string_literal: true

# One broker's running note against one training. Tenant data, unlike the
# training itself: it belongs to the firm whose user wrote it.
class TrainingNote < ApplicationRecord
  include FirmScoped

  BODY_MAX = 20_000

  # The key here is user_id, so the default scope's `firm_id IS NULL` would
  # survive into this association — see PROJECT_THEORY invariant 4.
  belongs_to :user, -> { unscope(where: :firm_id) }
  belongs_to_same_firm :user
  belongs_to :training

  validates :body, presence: true, length: { maximum: BODY_MAX }
  validates :user_id, uniqueness: { scope: :training_id }
end
