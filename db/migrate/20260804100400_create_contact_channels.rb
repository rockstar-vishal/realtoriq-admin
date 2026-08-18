# frozen_string_literal: true

# The firm's verifiable contact points — email, mobile, WhatsApp.
#
# These belong to the FIRM, not to individual users. A user's own mobile still
# receives the login OTP, but that is authentication (proving possession at
# sign-in), not channel verification: no badge, no state machine, nothing for
# ops to chase per person.
#
# WhatsApp is its own row rather than a flag on the mobile channel, because a
# firm's WhatsApp Business number is frequently not its stated contact number.
class CreateContactChannels < ActiveRecord::Migration[8.0]
  def change
    create_table :contact_channels, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.references :firm, null: false, foreign_key: true, type: :uuid

      t.string :kind, null: false
      # Normalised on write: E.164 for phone numbers, downcased for email.
      t.string :value, null: false

      t.string   :verification_state, null: false, default: "unverified"
      t.datetime :verified_at
      # Null when ops verified it from the admin panel rather than the firm's
      # super_admin doing it from the broker app.
      t.references :verified_by_user, foreign_key: { to_table: :users }, type: :uuid

      t.integer  :verification_attempts, null: false, default: 0
      t.datetime :last_code_sent_at

      t.timestamps
    end

    add_index :contact_channels, [ :firm_id, :kind ], unique: true

    add_check_constraint :contact_channels,
      "kind IN ('email', 'mobile', 'whatsapp')",
      name: "contact_channels_kind_check"

    add_check_constraint :contact_channels,
      "verification_state IN ('unverified', 'pending', 'verified', 'failed')",
      name: "contact_channels_verification_state_check"
  end
end
