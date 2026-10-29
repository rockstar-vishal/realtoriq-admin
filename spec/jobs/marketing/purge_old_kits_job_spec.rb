# frozen_string_literal: true

require "rails_helper"

RSpec.describe Marketing::PurgeOldKitsJob do
  let(:firm) { create(:firm, status: :active) }
  let(:catalog) do
    Current.set(firm_scope_bypassed: true) do
      create(:project, :catalog, firm: nil)
    end
  end

  before { catalog }

  def kit(status:, age:)
    row = Current.set(firm:) do
      MicrositeKit.create!(project: catalog, firm:, fingerprint: SecureRandom.hex(8), status:)
    end
    row.file.attach(io: StringIO.new("zip"), filename: "kit.zip", content_type: "application/zip")
    row.update_columns(created_at: age.ago)
    row
  end

  it "deletes a ready kit older than 30 days" do
    old = kit(status: "ready", age: 31.days)
    described_class.perform_now
    expect(MicrositeKit.across_firms.find_by(id: old.id)).to be_nil
  end

  it "keeps a ready kit that is 29 days old" do
    recent = kit(status: "ready", age: 29.days)
    described_class.perform_now
    expect(MicrositeKit.across_firms.find_by(id: recent.id)).to be_present
  end

  it "deletes a failed kit older than a day" do
    failed = kit(status: "failed", age: 2.days)
    described_class.perform_now
    expect(MicrositeKit.across_firms.find_by(id: failed.id)).to be_nil
  end
end
