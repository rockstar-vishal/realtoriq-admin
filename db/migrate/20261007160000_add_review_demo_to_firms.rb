# frozen_string_literal: true

# One production firm for Meta's App Review. The partial unique index is the
# database half of "at most one"; the rake task is the only writer.
class AddReviewDemoToFirms < ActiveRecord::Migration[8.0]
  def change
    add_column :firms, :review_demo, :boolean, default: false, null: false
    add_index :firms, :review_demo, unique: true, where: "review_demo",
      name: "index_firms_one_review_demo"
  end
end
