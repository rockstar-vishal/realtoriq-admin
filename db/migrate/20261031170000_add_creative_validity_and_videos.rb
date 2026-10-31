# frozen_string_literal: true

class AddCreativeValidityAndVideos < ActiveRecord::Migration[8.1]
  def change
    change_table :project_creatives, bulk: true do |t|
      t.date :valid_until
      t.string :video_url, limit: 2048
      t.string :video_provider
    end
  end
end
