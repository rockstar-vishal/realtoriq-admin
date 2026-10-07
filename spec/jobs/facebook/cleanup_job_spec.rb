# frozen_string_literal: true

require "rails_helper"

RSpec.describe Facebook::CleanupJob do
  let(:firm) { create(:firm) }
  let(:owner) { create(:user, :super_admin, firm:) }
  let(:page) { create(:facebook_page, firm:, facebook_connection: create(:facebook_connection, firm:, connected_by_user: owner)) }

  def age(record, time)
    Current.set(firm:) { record.update_columns(created_at: time, updated_at: time) }
  end

  it "deletes old attempts and finished imports, and keeps the rest" do
    old_attempt = create(:facebook_oauth_attempt, firm:, user: owner)
    fresh_attempt = create(:facebook_oauth_attempt, firm:, user: owner)
    age(old_attempt, 2.days.ago)

    old_dead = create(:facebook_lead_import, firm:, facebook_page: page, status: "dead")
    fresh_dead = create(:facebook_lead_import, firm:, facebook_page: page, status: "dead")
    old_created = create(:facebook_lead_import, firm:, facebook_page: page, status: "created")
    old_failed = create(:facebook_lead_import, firm:, facebook_page: page, status: "failed")
    age(old_dead, 31.days.ago)
    age(fresh_dead, 2.days.ago)
    age(old_created, 181.days.ago)
    age(old_failed, 200.days.ago)

    described_class.perform_now

    ids = FacebookLeadImport.across_firms.where(firm_id: firm.id).pluck(:id)
    expect(ids).to contain_exactly(fresh_dead.id, old_failed.id)
    expect(FacebookOauthAttempt.across_firms.where(firm_id: firm.id).pluck(:id)).to eq([ fresh_attempt.id ])
  end
end
