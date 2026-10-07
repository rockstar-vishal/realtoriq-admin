# frozen_string_literal: true

require "rails_helper"

RSpec.describe Leads::TransitionStatus do
  let(:firm) { create(:firm, status: :active) }
  let!(:new_status) { create(:lead_status, :new_lead) }
  let!(:dead_status) { create(:lead_status, :dead) }
  let(:actor) { create(:user, :manager, firm:) }

  before { Current.firm = firm }

  it "turns a unique-index race into duplicate_lead" do
    dead = create(:lead, firm:, lead_status: new_status, transaction_type: "sale")
    described_class.new(lead: dead, to_status: dead_status, actor:, reason: "Gone quiet").call
    live = create(:lead, firm:, mobile: dead.mobile, lead_status: new_status, transaction_type: "sale")
    dead.reload
    allow(dead).to receive(:duplicate_on_mobile_and_type).and_return(nil, live)
    allow(dead).to receive(:save!).and_raise(
      ActiveRecord::RecordNotUnique.new(
        'duplicate key value violates unique constraint "index_leads_on_firm_type_and_open_identity"'
      )
    )

    result = described_class.new(lead: dead, to_status: new_status, actor:).call

    expect(result.error_code).to eq("duplicate_lead")
    expect(result.error_details).to include(lead_id: live.id, transaction_type: "sale")
  end
end
