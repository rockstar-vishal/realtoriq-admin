# frozen_string_literal: true

require "rails_helper"

# The Indian FY runs 1 April to 31 March. Every "by FY month" report in
# docs/schema.md depends on this boundary, and getting it wrong is quiet — a
# January booking counted into the wrong year still looks plausible.
RSpec.describe FinancialYear do
  describe ".year_of" do
    it "names the FY by the calendar year it starts in" do
      expect(described_class.year_of(Date.new(2026, 4, 1))).to eq(2026)
      expect(described_class.year_of(Date.new(2026, 12, 31))).to eq(2026)
    end

    it "puts January to March in the year before" do
      expect(described_class.year_of(Date.new(2027, 1, 1))).to eq(2026)
      expect(described_class.year_of(Date.new(2027, 3, 31))).to eq(2026)
    end
  end

  it "spans 1 April to 31 March" do
    expect(described_class.starts_on(Date.new(2026, 9, 10))).to eq(Date.new(2026, 4, 1))
    expect(described_class.ends_on(Date.new(2026, 9, 10))).to eq(Date.new(2027, 3, 31))
  end

  it "puts 31 March and 1 April in different years" do
    expect(described_class.year_of(Date.new(2026, 3, 31)))
      .not_to eq(described_class.year_of(Date.new(2026, 4, 1)))
  end

  it "labels it the way a broker writes it" do
    expect(described_class.label(Date.new(2026, 9, 10))).to eq("2026-27")
    expect(described_class.label(Date.new(2027, 2, 1))).to eq("2026-27")
    # The century roll, which a naive "#{y}-#{y + 1}"[-2..] would get wrong.
    expect(described_class.label(Date.new(2099, 6, 1))).to eq("2099-00")
  end
end
