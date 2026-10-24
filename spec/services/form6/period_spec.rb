# frozen_string_literal: true

require "rails_helper"

RSpec.describe Form6::Period do
  describe ".parse" do
    it "builds the two halves and their due dates" do
      april = described_class.parse("2026-04")
      expect(april.from).to eq(Date.new(2026, 4, 1))
      expect(april.to).to eq(Date.new(2026, 9, 30))
      expect(april.due_on).to eq(Date.new(2026, 10, 20))
      expect(april.filename_part).to eq("Apr-Sep-2026")

      october = described_class.parse("2025-10")
      expect(october.from).to eq(Date.new(2025, 10, 1))
      expect(october.to).to eq(Date.new(2026, 3, 31))
      expect(october.due_on).to eq(Date.new(2026, 4, 20))
      expect(october.filename_part).to eq("Oct-2025-Mar-2026")
    end

    it "rejects a month that is not the start of a half" do
      expect(described_class.parse("2026-05")).to be_nil
      expect(described_class.parse("nope")).to be_nil
    end
  end

  describe ".completed" do
    it "returns the newest half that has fully ended" do
      expect(described_class.completed(today: Date.new(2026, 9, 30)).first.id).to eq("2025-10")
      expect(described_class.completed(today: Date.new(2026, 10, 1)).first.id).to eq("2026-04")
      expect(described_class.completed(today: Date.new(2026, 10, 24)).map(&:id).first(2)).to eq(%w[2026-04 2025-10])
      expect(described_class.completed(today: Date.new(2026, 4, 1)).first.id).to eq("2025-10")
      expect(described_class.completed(limit: 6, today: Date.new(2026, 10, 24)).size).to eq(6)
    end
  end
end
