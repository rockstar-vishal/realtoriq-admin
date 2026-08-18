# frozen_string_literal: true

# Per-request state. `firm` is the one that matters: FirmScoped reads it to
# scope every query, so whatever sets it is effectively deciding which tenant's
# data this request can see.
#
# It is set in exactly two places, both deliberate:
#   - Api::V1::BaseController, from the verified JWT's firm claim
#   - the admin panel, when a controller narrows to a single firm
#
# Never set it from a request header, param or subdomain.
class Current < ActiveSupport::CurrentAttributes
  attribute :firm, :user, :admin_user, :request_ip, :user_agent

  # Lifts the tenant scope entirely, so firm-scoped models read across every
  # firm. Set in exactly one place — Admin::BaseController — because the admin
  # panel's whole job is cross-tenant. Nothing in the broker API may set it.
  #
  # The trap it closes is joins, not associations. `firm.users` is safe on its
  # own: Rails replaces the default scope's firm_id condition with the
  # association's foreign key. But `Firm.left_joins(:users)` puts the default
  # scope's `users.firm_id IS NULL` into the WHERE clause alongside the join,
  # which silently eliminates every row. See the specs in
  # spec/models/tenancy_isolation_spec.rb, which pin both behaviours down.
  attribute :firm_scope_bypassed

  def firm_id
    firm&.id
  end
end
