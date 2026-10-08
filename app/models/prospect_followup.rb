# frozen_string_literal: true

# One call logged against a prospect. The prospect's current next_action_at is
# a copy, written by Prospects::RecordFollowup, the same way a lead's NCD is.
class ProspectFollowup < ApplicationRecord
  include FirmScoped

  OUTCOMES = %w[retry not_sure interested not_interested].freeze

  enum :outcome, OUTCOMES.index_by(&:itself), validate: true

  belongs_to :prospect, -> { unscope(where: :firm_id) }
  belongs_to :user, -> { unscope(where: :firm_id) }, optional: true

  validates :notes, presence: true
  validates :connected, inclusion: { in: [ true, false ] }

  def self.latest_notes_for(prospect_ids)
    return {} if prospect_ids.empty?

    where(prospect_id: prospect_ids)
      .select(Arel.sql(<<~SQL.squish))
        DISTINCT ON (prospect_followups.prospect_id)
        prospect_followups.prospect_id,
        prospect_followups.notes
      SQL
      .order(Arel.sql("prospect_followups.prospect_id, prospect_followups.created_at DESC, prospect_followups.id::text DESC"))
      .each_with_object({}) { |row, map| map[row.prospect_id] = row.notes }
  end
end
