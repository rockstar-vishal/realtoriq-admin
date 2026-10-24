# frozen_string_literal: true

require "rails_helper"

RSpec.describe Form6::Money do
  it "groups rupees the Indian way, without a rupee sign" do
    expect(described_class.group(300_000)).to eq("3,00,000")
    expect(described_class.group(752_000)).to eq("7,52,000")
    expect(described_class.group(1_000)).to eq("1,000")
    expect(described_class.group(100)).to eq("100")
    expect(described_class.group(0)).to eq("0")
  end
end
