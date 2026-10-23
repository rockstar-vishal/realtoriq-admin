# frozen_string_literal: true

class AddReviewNoteToProjectTypologies < ActiveRecord::Migration[8.0]
  def change
    add_column :project_typologies, :review_note, :string, limit: 255
  end
end
