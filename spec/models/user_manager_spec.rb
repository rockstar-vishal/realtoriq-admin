# frozen_string_literal: true

require "rails_helper"

RSpec.describe UserManager do
  let(:firm) { create(:firm) }
  let(:boss) { create(:user, :manager, firm:) }
  let(:report) { create(:user, firm:, role: :agent) }

  def connect(manager:, user:)
    create(:user_manager, manager:, user:, firm: user.firm)
  end

  describe "validity" do
    it "accepts a reporting line inside the firm" do
      expect(build(:user_manager, user: report, manager: boss, firm:)).to be_valid
    end

    it "lets a person have two managers" do
      other = create(:user, :manager, firm:)
      connect(manager: boss, user: report)
      expect(build(:user_manager, user: report, manager: other, firm:)).to be_valid
    end

    it "lets an agent be a manager of someone else" do
      junior = create(:user, firm:, role: :agent)
      expect(build(:user_manager, user: junior, manager: report, firm:)).to be_valid
    end

    it "rejects a person as their own manager" do
      link = build(:user_manager, user: report, manager: report, firm:)
      expect(link).not_to be_valid
      expect(link.errors[:manager_id]).to be_present
    end

    it "rejects a duplicate pair" do
      connect(manager: boss, user: report)
      dup = build(:user_manager, user: report, manager: boss, firm:)
      expect(dup).not_to be_valid
      expect(dup.errors[:user_id]).to be_present
    end

    it "rejects the super admin on either end" do
      admin = create(:user, :super_admin, firm:)
      as_boss = build(:user_manager, user: report, manager: admin, firm:)
      as_report = build(:user_manager, user: admin, manager: boss, firm:)

      expect(as_boss).not_to be_valid
      expect(as_report).not_to be_valid
    end

    it "rejects a manager from another firm" do
      stranger = create(:user, :manager, firm: create(:firm))
      link = build(:user_manager, user: report, manager: stranger, firm:)
      expect(link).not_to be_valid
      expect(link.errors[:manager_id]).to include("isn't one of this firm's records")
    end
  end

  describe "cycles" do
    it "rejects A ↔ B" do
      connect(manager: boss, user: report)
      back = build(:user_manager, user: boss, manager: report, firm:)

      expect(back).not_to be_valid
      expect(back.errors).to be_added(:manager_id, :reporting_cycle)
    end

    it "rejects A → B → C → A" do
      mid = create(:user, :manager, firm:)
      connect(manager: boss, user: mid)
      connect(manager: mid, user: report)
      back = build(:user_manager, user: boss, manager: report, firm:)

      expect(back).not_to be_valid
      expect(back.errors).to be_added(:manager_id, :reporting_cycle)
    end

    it "allows a diamond: two managers of the same person, both reporting to one root" do
      left = create(:user, :manager, firm:)
      right = create(:user, :manager, firm:)
      leaf = create(:user, firm:, role: :agent)

      connect(manager: boss, user: left)
      connect(manager: boss, user: right)
      connect(manager: left, user: leaf)
      expect(build(:user_manager, user: leaf, manager: right, firm:)).to be_valid
    end

    it "does not loop when a cycle was inserted past validation" do
      now = Time.current
      UserManager.across_firms.insert_all([
        { firm_id: firm.id, user_id: report.id, manager_id: boss.id, created_at: now, updated_at: now },
        { firm_id: firm.id, user_id: boss.id, manager_id: report.id, created_at: now, updated_at: now }
      ])

      ids = nil
      expect {
        User.connection.transaction(requires_new: true) do
          User.connection.execute("SET LOCAL statement_timeout = '1500ms'")
          ids = User.manageable_ids_for(boss)
        end
      }.not_to raise_error
      expect(ids).to contain_exactly(boss.id.to_s, report.id.to_s)
    end
  end
end
