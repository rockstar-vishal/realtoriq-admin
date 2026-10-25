# frozen_string_literal: true

# A handoff ticket lets the installed app open Facebook without a second
# RealtorIQ sign-in. Only the digest is stored. The ticket works once.
class AddHandoffToFacebookOauthAttempts < ActiveRecord::Migration[8.0]
  def change
    change_table :facebook_oauth_attempts, bulk: true do |t|
      t.boolean :handoff, null: false, default: false
      t.string :handoff_ticket_digest
      t.datetime :handoff_expires_at
      t.datetime :handoff_used_at
    end
    add_index :facebook_oauth_attempts, :handoff_ticket_digest
  end
end
