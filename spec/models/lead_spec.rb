# frozen_string_literal: true

require "rails_helper"

RSpec.describe Lead do
  let(:firm) { create(:firm) }

  before { Current.firm = firm }

  describe "transaction type and property type" do
    it "requires a property type on a sale lead" do
      expect(build(:lead, firm:, transaction_type: "sale", property_type: nil)).not_to be_valid
    end

    it "refuses a property type on a rental lead" do
      # The design's form drops the question entirely for rentals, so one
      # arriving means the client sent something the user never chose.
      lead = build(:lead, firm:, transaction_type: "rent", property_type: create(:property_type))

      expect(lead).not_to be_valid
      expect(lead.errors[:property_type_id]).to include("is not asked for a rental lead")
    end

    it "accepts a rental lead without one" do
      expect(build(:lead, :rent, firm:)).to be_valid
    end
  end

  describe "the name" do
    it "is optional — brokers capture a number first" do
      expect(build(:lead, firm:, name: nil)).to be_valid
    end

    it "falls back to the formatted mobile for display" do
      lead = build(:lead, firm:, name: nil, mobile: "9820144210")

      expect(lead.display_name).to eq("+91 98201 44210")
    end
  end

  describe "codes" do
    it "starts at L-0001 for a firm" do
      expect(create(:lead, firm:).code).to eq("L-0001")
    end

    it "increments per firm" do
      create(:lead, firm:)
      expect(create(:lead, firm:).code).to eq("L-0002")
    end

    it "numbers each firm independently" do
      create(:lead, firm:)
      other = create(:firm)
      Current.firm = other

      expect(create(:lead, firm: other).code).to eq("L-0001")
    end

    it "compares numerically, so it doesn't reissue past L-9999" do
      # A string MAX would rank 'L-9999' above 'L-10000' and hand out a
      # duplicate. Ordering is on the digits, not the text.
      create(:lead, firm:, code: "L-9999")

      expect(create(:lead, firm:).code).to eq("L-10000")
    end
  end

  describe "budget filtering" do
    it "matches the stored amount inside the window, not a range overlap" do
      in_window = create(:lead, firm:, budget_min: nil, budget_max: 12_000_000)
      leftover_min = create(:lead, firm:, budget_min: 12_000_000, budget_max: nil)
      # Old overlap semantics would include this; the stored max is below the window.
      outside_max = create(:lead, firm:, budget_min: 8_000_000, budget_max: 9_000_000)
      below = create(:lead, firm:, budget_min: nil, budget_max: 2_000_000)

      found = described_class.budget_between(10_000_000, 13_000_000).pluck(:id)

      expect(found).to include(in_window.id, leftover_min.id)
      expect(found).not_to include(outside_max.id, below.id)
    end

    it "treats a leftover open-ended min as the stored amount" do
      leftover = create(:lead, firm:, budget_min: 9_000_000, budget_max: nil)

      expect(described_class.budget_between(8_000_000, 10_000_000).pluck(:id))
        .to include(leftover.id)
      expect(described_class.budget_between(20_000_000, 30_000_000).pluck(:id))
        .not_to include(leftover.id)
    end
  end

  describe "missed followup" do
    it "is derived from an overdue next action, not a status" do
      overdue = create(:lead, :overdue, firm:)
      create(:lead, :upcoming, firm:)

      expect(described_class.missed_followup.pluck(:id)).to eq([ overdue.id ])
    end

    it "includes a followup due exactly now" do
      due_now = create(:lead, firm:, next_action_at: Time.current)
      create(:lead, :upcoming, firm:)

      expect(described_class.missed_followup.pluck(:id)).to eq([ due_now.id ])
    end

    it "excludes leads in a terminal status, which need no chasing" do
      create(:lead, :overdue, firm:, lead_status: create(:lead_status, :dead), dead_reason: "Gone")

      expect(described_class.missed_followup.count).to eq(0)
    end

    it "is not reachable as a status code" do
      create(:lead, :overdue, firm:)

      expect(described_class.with_status("missed_followup")).to be_empty
    end

    it "filters through with_missed_followup" do
      overdue = create(:lead, :overdue, firm:)
      upcoming = create(:lead, :upcoming, firm:)

      expect(described_class.with_missed_followup(true).pluck(:id)).to eq([ overdue.id ])
      expect(described_class.with_missed_followup(false).pluck(:id)).to eq([ upcoming.id ])
    end

    it "expands hot_negotiation to the hot and negotiation codes" do
      hot = create(:lead, firm:, lead_status: create(:lead_status, :hot))
      negotiation = create(:lead, firm:, lead_status: create(:lead_status, :negotiation))
      create(:lead, firm:)

      expect(described_class.with_status("hot_negotiation").pluck(:id))
        .to contain_exactly(hot.id, negotiation.id)
    end
  end

  describe "visibility" do
    let(:agent) { create(:user, firm:, role: :agent) }
    let(:manager) { create(:user, firm:, role: :manager) }

    it "limits an agent to their own leads" do
      mine = create(:lead, firm:, assigned_user: agent)
      create(:lead, firm:, assigned_user: manager)
      create(:lead, firm:, assigned_user: nil)

      expect(described_class.visible_to(agent).pluck(:id)).to eq([ mine.id ])
    end

    it "shows a manager everything, including unassigned" do
      create(:lead, firm:, assigned_user: agent)
      create(:lead, firm:, assigned_user: nil)

      expect(described_class.visible_to(manager).count).to eq(2)
    end
  end

  describe "#possible_duplicates" do
    it "finds the other transaction type on the same number, excluding itself" do
      first = create(:lead, firm:, mobile: "9820144210")
      second = create(:lead, :rent, firm:, mobile: "+919820144210")

      expect(second.possible_duplicates.pluck(:id)).to eq([ first.id ])
    end
  end

  describe "uniqueness" do
    it "refuses a second sale lead on the same number" do
      create(:lead, firm:, mobile: "9820144210")

      expect(build(:lead, firm:, mobile: "+919820144210")).not_to be_valid
    end

    it "allows sale and rent on the same number" do
      create(:lead, firm:, mobile: "9820144210")

      expect(build(:lead, :rent, firm:, mobile: "+919820144210")).to be_valid
    end
  end

  describe "validations" do
    it "rejects a budget maximum below the minimum" do
      expect(build(:lead, firm:, budget_min: 5_000_000, budget_max: 1_000_000)).not_to be_valid
    end

    it "normalises the mobile to E.164" do
      expect(create(:lead, firm:, mobile: "098201 44210").mobile).to eq("+919820144210")
    end

    it "requires a reason once the status is a dead one" do
      lead = build(:lead, firm:, lead_status: create(:lead_status, :dead), dead_reason: nil)

      expect(lead).not_to be_valid
    end
  end
end
