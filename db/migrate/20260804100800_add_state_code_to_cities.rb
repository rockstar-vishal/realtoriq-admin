# frozen_string_literal: true

# Firm codes read CP-MH-04218, not CP-MA-04218 — MH is Maharashtra's actual
# state code, which you cannot derive by truncating the name (Maharashtra vs
# Madhya Pradesh both start "MA"). So it gets stored rather than guessed.
class AddStateCodeToCities < ActiveRecord::Migration[8.0]
  STATE_CODES = {
    "Maharashtra" => "MH", "Karnataka" => "KA", "Delhi" => "DL", "Haryana" => "HR",
    "Uttar Pradesh" => "UP", "Gujarat" => "GJ", "Tamil Nadu" => "TN", "Telangana" => "TG",
    "West Bengal" => "WB", "Rajasthan" => "RJ", "Madhya Pradesh" => "MP", "Punjab" => "PB",
    "Kerala" => "KL", "Goa" => "GA", "Andhra Pradesh" => "AP", "Bihar" => "BR",
    "Odisha" => "OD", "Chandigarh" => "CH", "Jharkhand" => "JH", "Assam" => "AS",
    "Uttarakhand" => "UK", "Chhattisgarh" => "CG", "Himachal Pradesh" => "HP"
  }.freeze

  def up
    add_column :cities, :state_code, :string

    STATE_CODES.each do |state, code|
      execute ActiveRecord::Base.sanitize_sql(
        [ "UPDATE cities SET state_code = ? WHERE state = ?", code, state ]
      )
    end

    # Anything unrecognised falls back to the first two letters, which is at
    # least stable, and ops can correct it from the masters screen.
    execute "UPDATE cities SET state_code = UPPER(LEFT(state, 2)) WHERE state_code IS NULL"

    change_column_null :cities, :state_code, false
  end

  def down
    remove_column :cities, :state_code
  end
end
