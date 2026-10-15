# frozen_string_literal: true

class AllowBlankLegalNameOnOnboardingApplications < ActiveRecord::Migration[8.0]
  def change
    change_column_null :onboarding_applications, :legal_name, true
  end
end
