# frozen_string_literal: true

# Row-level tenancy. Every firm-owned model includes this, and the guard spec in
# spec/models/tenancy_isolation_spec.rb fails the build if one forgets to.
#
# The default scope is deliberately FAIL-CLOSED: with no Current.firm set the
# where clause becomes `firm_id IS NULL`, which matches nothing. A request that
# forgets to establish a tenant therefore sees an empty result, never another
# firm's rows. Cross-firm reads have to ask for it by name.
module FirmScoped
  extend ActiveSupport::Concern

  included do
    belongs_to :firm

    default_scope do
      Current.firm_scope_bypassed ? all : where(firm_id: Current.firm_id)
    end

    before_validation :assign_current_firm, on: :create
  end

  class_methods do
    # The admin panel works across every tenant. Making that an explicit call
    # keeps cross-firm access something you opt into, not something you get by
    # forgetting to set Current.firm.
    def across_firms
      unscope(where: :firm_id)
    end
  end

  private

  def assign_current_firm
    self.firm_id ||= Current.firm_id
  end
end
