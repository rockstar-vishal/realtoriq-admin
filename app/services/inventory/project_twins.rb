# frozen_string_literal: true

module Inventory
  # A firm's booking copy and the catalog row share external_ref. While anchor
  # matching is on they are one project: one anchor, one match row, and a
  # shortlist entry for either marks both.
  module ProjectTwins
    module_function

    # Own projects whose catalog row is still active are left out. A null
    # external_ref is not in that set. where.not(external_ref: subquery)
    # alone would drop those nulls, so the null arm is written out.
    def without_listed_copies(scope)
      listed = Project.marketplace.where.not(external_ref: nil).select(:external_ref)
      scope.where(external_ref: nil).or(scope.where.not(external_ref: listed))
    end

    # The given ids plus every own or catalog project with the same
    # non-null external_ref. Withdrawn catalog rows count. A null ref does
    # not pull in other projects.
    def expand(project_ids, firm_id:)
      ids = Array(project_ids).compact.uniq
      return ids if ids.empty?

      refs = Project.unscoped.where(id: ids).where.not(external_ref: nil).distinct.pluck(:external_ref)
      return ids if refs.empty?

      twins = Project.unscoped.where(external_ref: refs)
        .where("firm_id = ? OR firm_id IS NULL", firm_id)
        .pluck(:id)
      (ids + twins).uniq
    end
  end
end
