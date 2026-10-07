# frozen_string_literal: true

module Auth
  # Owner decision 7 Oct 2026. Aarav Realty and Deshmukh Properties are the
  # firms the team carries into a broker's office. Every OTP for every user
  # of a firm flagged field_demo is 888888, and nothing is sent. The rest of
  # the app is a normal firm. This is not the Meta review account.
  module FieldDemo
    CODE = "888888"
    FIRM_NAMES = [ "Aarav Realty", "Deshmukh Properties" ].freeze

    module_function

    def applies_to?(user)
      user.present? && user.firm&.field_demo?
    end
  end
end
