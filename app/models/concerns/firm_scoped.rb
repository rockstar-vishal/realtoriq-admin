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

    # Guards a foreign key that points at another firm-owned row.
    #
    # `belongs_to ... -> { unscope(where: :firm_id) }` is right for reading —
    # see docs/schema.md — but it rests on an assumption: that reaching the
    # parent at all meant the tenant check had happened, so the id was
    # trustworthy when it was written. Where a **client supplies the id**, that
    # assumption is simply false, and the unscoped association then reads the
    # other firm's row back quite happily.
    #
    # Two of those were live: a firm could attach another firm's project to its
    # own booking and read the project name back, and could create a lead
    # assigned to another firm's user and read that person's name. Both returned
    # 404 through the front door and answered through this side one.
    #
    # A validation rather than a controller check, so it holds for every write
    # path — console sessions and future code included.
    def belongs_to_same_firm(*names)
      names.each do |name|
        validate do
          related = public_send(name)
          next if related.nil? || related.firm_id == firm_id

          errors.add(:"#{name}_id", "isn't one of this firm's records")
        end
      end
    end
  end

  private

  def assign_current_firm
    self.firm_id ||= Current.firm_id
  end
end
