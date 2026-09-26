# frozen_string_literal: true

# One saved Quick EMI calculation per lead. The three inputs are stored; the
# monthly figure is derived when the screen opens, so a stored total cannot
# drift from the sliders. All four columns are null together until the first save.
class AddEmiToLeads < ActiveRecord::Migration[8.0]
  def change
    change_table :leads, bulk: true do |t|
      t.bigint :emi_loan_amount
      t.decimal :emi_annual_rate, precision: 5, scale: 2
      t.integer :emi_tenure_years
      t.datetime :emi_saved_at
    end

    add_check_constraint :leads,
      "emi_loan_amount IS NULL OR emi_loan_amount BETWEEN 500000 AND 50000000",
      name: "leads_emi_loan_amount_check"
    add_check_constraint :leads,
      "emi_annual_rate IS NULL OR emi_annual_rate BETWEEN 6 AND 14",
      name: "leads_emi_annual_rate_check"
    add_check_constraint :leads,
      "emi_tenure_years IS NULL OR emi_tenure_years BETWEEN 1 AND 30",
      name: "leads_emi_tenure_years_check"
    add_check_constraint :leads,
      "(emi_loan_amount IS NULL AND emi_annual_rate IS NULL AND emi_tenure_years IS NULL AND emi_saved_at IS NULL) OR " \
      "(emi_loan_amount IS NOT NULL AND emi_annual_rate IS NOT NULL AND emi_tenure_years IS NOT NULL AND emi_saved_at IS NOT NULL)",
      name: "leads_emi_all_or_nothing_check"
  end
end
