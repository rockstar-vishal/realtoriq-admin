# frozen_string_literal: true

module Auth
  # Owner-approved exception to AGENTS.md rule 6 (7 Oct 2026): Meta's App Review
  # team signs in to production with this one account. See docs/review_demo.md.
  module ReviewLogin
    MOBILE = "+919876754543"
    CODE   = "888888"

    module_function

    def applies_to?(user)
      user.present? && user.mobile == MOBILE && user.firm&.review_demo?
    end
  end
end
