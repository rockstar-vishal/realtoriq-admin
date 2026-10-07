# frozen_string_literal: true

# One row per firm. Holds the clocks for the failure digest and the
# duplicate notice so a burst does not send a message for every lead.
class FacebookImportAlertState < ApplicationRecord
  include FirmScoped

  validates :firm_id, uniqueness: true

  def self.for_firm!(firm)
    firm_record = firm.is_a?(Firm) ? firm : Firm.find(firm)
    Current.set(firm: firm_record) do
      find_or_create_by!(firm_id: firm_record.id)
    end
  rescue ActiveRecord::RecordNotUnique
    across_firms.find_by!(firm_id: firm_record.id)
  end
end
