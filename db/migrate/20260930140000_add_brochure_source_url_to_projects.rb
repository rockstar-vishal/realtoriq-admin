# frozen_string_literal: true

# Marketplace brochures stay on LaunchIQ. This is that file's URL.
# A firm's own project keeps its uploaded PDF and leaves this blank.
class AddBrochureSourceUrlToProjects < ActiveRecord::Migration[8.0]
  def change
    add_column :projects, :brochure_source_url, :text
  end
end
