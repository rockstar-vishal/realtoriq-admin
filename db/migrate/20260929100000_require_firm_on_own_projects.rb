# frozen_string_literal: true

# Marketplace catalog rows are the only projects with no firm. An own project
# with a blank firm would pass the model and then be invisible, or visible to
# every job that reads firm_id IS NULL. The database refuses that write.
class RequireFirmOnOwnProjects < ActiveRecord::Migration[8.0]
  def change
    add_check_constraint :projects,
      "firm_id IS NOT NULL OR source = 'catalog'",
      name: "projects_firm_required_unless_catalog"
  end
end
