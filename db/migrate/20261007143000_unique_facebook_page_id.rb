# frozen_string_literal: true

# A Facebook Page belongs to one firm. Disconnect keeps the row, so the Page
# stays with that firm until the row is gone.
class UniqueFacebookPageId < ActiveRecord::Migration[8.0]
  def change
    remove_index :facebook_pages, name: "index_facebook_pages_on_page_id"
    remove_index :facebook_pages, name: "index_facebook_pages_on_firm_id_and_page_id"
    add_index :facebook_pages, :page_id, unique: true, name: "index_facebook_pages_on_page_id"
  end
end
