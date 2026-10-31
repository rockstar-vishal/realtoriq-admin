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

  it "deletes personalised copies of creatives that expired more than 7 days ago" do
    firm.update!(name: "FIRMNAMELEAK")
    today = ProjectCreative.today_ist
    old = creative_on(today - 8)
    boundary = creative_on(today - 7)
    recent = creative_on(today - 6)
    open = creative_on(nil)
    old_copy = personalised(old)
    boundary_copy = personalised(boundary)
    recent_copy = personalised(recent)
    open_copy = personalised(open)
    lines = []
    allow(Rails.logger).to receive(:info).and_wrap_original do |method, *args|
      lines << args.first.to_s
      method.call(*args)
    end

    described_class.perform_now

    expect(PersonalisedCreative.across_firms.find_by(id: old_copy.id)).to be_nil
    expect(ProjectCreative.find_by(id: old.id)).to be_present
    expect(PersonalisedCreative.across_firms.where(id: [ boundary_copy.id, recent_copy.id, open_copy.id ]).count).to eq(3)
    logged = lines.find { |line| line.include?("Expired personalised creatives purged") }
    expect(logged).to eq("Expired personalised creatives purged: 1")
    expect(lines.join).not_to include("FIRMNAMELEAK")
    expect(lines.join).not_to include("secret-copy.png")
  end

  def creative_on(valid_until)
    ProjectCreative.create!(
      project: catalog, external_id: "crt_#{valid_until || "open"}", title: "Frame", kind: "image",
      position: 1, registration_numbers: [], checksum: "pending", valid_until:
    )
  end

  def personalised(creative)
    Current.set(firm:) do
      row = PersonalisedCreative.create!(project_creative: creative, firm:, fingerprint: SecureRandom.hex(8))
      row.file.attach(io: StringIO.new("bytes"), filename: "secret-copy.png", content_type: "image/png")
      row
    end
  end
end
