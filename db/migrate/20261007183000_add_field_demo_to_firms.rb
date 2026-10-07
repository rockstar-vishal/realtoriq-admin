# frozen_string_literal: true

# Field-demo firms (Aarav Realty, Deshmukh Properties). Unlike review_demo this
# is not unique: two firms, and the rest of the app stays available. The rake
# task is the only writer.
class AddFieldDemoToFirms < ActiveRecord::Migration[8.0]
  def change
    add_column :firms, :field_demo, :boolean, default: false, null: false
  end
end
