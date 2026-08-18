class ApplicationRecord < ActiveRecord::Base
  primary_abstract_class

  # Postgres 14 can't generate v7 uuids, so mint the key here. The column
  # default (gen_random_uuid) still covers inserts that bypass Rails entirely;
  # this callback just upgrades the common path to a time-ordered key.
  before_create :assign_uuid_v7_primary_key

  private

  def assign_uuid_v7_primary_key
    return unless self.class.primary_key == "id"
    return unless self.class.columns_hash["id"]&.type == :uuid

    self.id ||= UuidV7.generate
  end
end
