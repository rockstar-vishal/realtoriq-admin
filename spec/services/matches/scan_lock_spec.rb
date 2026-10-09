# frozen_string_literal: true

require "rails_helper"

RSpec.describe Matches::ScanLock do
  let(:firm) { create(:firm) }

  it "releases the firm lock when the block finishes or raises" do
    described_class.with(firm) do
      expect(described_class.held?(firm)).to be(true)
    end
    expect(described_class.held?(firm)).to be(false)

    expect { described_class.with(firm) { raise "stopped" } }.to raise_error(RuntimeError, "stopped")
    expect(described_class.held?(firm)).to be(false)
  end

  it "keeps an outer lock when an inner scan finishes" do
    described_class.lock(firm)
    begin
      described_class.with(firm) { expect(described_class.held?(firm)).to be(true) }
      expect(described_class.held?(firm)).to be(true)
    ensure
      described_class.unlock(firm)
    end
    expect(described_class.held?(firm)).to be(false)
  end
end
