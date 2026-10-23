# frozen_string_literal: true

require "rails_helper"

RSpec.describe Notifications::Record do
  let(:firm) { create(:firm) }
  let(:user) { create(:user, :super_admin, firm:) }

  before { Current.firm = firm }
  after { Current.reset }

  # The caller's transaction is joinable, the way CurateFirm's digest
  # transaction is. A duplicate dedupe key has to roll back only the insert.
  it "does not abort the caller's transaction when the dedupe key already exists" do
    user.notifications.create!(
      firm:, kind: "match_digest", title: "New matches are ready", body: "Already sent",
      dedupe_key: "match_digest:same", data: {}
    )

    sibling = nil
    expect {
      Notification.transaction do
        described_class.call(
          user:, kind: "match_digest", title: "New matches are ready", body: "Again",
          dedupe_key: "match_digest:same", data: {}
        )
        sibling = user.notifications.create!(
          firm:, kind: "match_digest", title: "New matches are ready", body: "Later",
          dedupe_key: "match_digest:other", data: {}
        )
      end
    }.not_to raise_error

    expect(sibling).to be_persisted
    expect(Notification.across_firms.where(dedupe_key: "match_digest:same").count).to eq(1)
    expect(Notification.across_firms.where(dedupe_key: "match_digest:other").count).to eq(1)
  end
end
