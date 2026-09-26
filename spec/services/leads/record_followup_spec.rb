# frozen_string_literal: true

require "rails_helper"

RSpec.describe Leads::RecordFollowup do
  let(:firm) { create(:firm) }
  let(:actor) { create(:user, :manager, firm:) }
  let(:new_status) { create(:lead_status, :new_lead) }
  let(:lead) { create(:lead, firm:, lead_status: new_status) }

  before { Current.firm = firm }
  after { Current.firm = nil }

  it "does not copy a blank NCD onto the lead" do
    lead.update!(next_action_at: 1.day.from_now)

    described_class.new(lead:, actor:, comment: "No date this time", next_action_at: "").call

    expect(lead.reload.next_action_at).to be_within(1.second).of(1.day.from_now)
  end
end
