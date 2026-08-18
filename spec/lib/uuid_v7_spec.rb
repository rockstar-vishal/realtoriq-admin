# frozen_string_literal: true

require "rails_helper"

RSpec.describe UuidV7 do
  describe ".generate" do
    it "produces a canonical uuid string" do
      expect(described_class.generate).to match(
        /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/
      )
    end

    it "sets the version nibble to 7" do
      # Version lives in the first nibble of the third group.
      expect(described_class.generate.split("-")[2][0]).to eq("7")
    end

    it "sets the RFC 9562 variant bits to 0b10" do
      # Variant lives in the top two bits of the fourth group, so the first
      # nibble is one of 8, 9, a, b.
      variants = Array.new(200) { described_class.generate.split("-")[3][0] }
      expect(variants.uniq).to all(match(/[89ab]/))
    end

    it "encodes the current time in the leading 48 bits" do
      before = (Time.now.to_f * 1000).to_i
      uuid = described_class.generate
      after = (Time.now.to_f * 1000).to_i

      ms = uuid.delete("-")[0, 12].to_i(16)
      expect(ms).to be_between(before, after)
    end

    it "is unique across many calls" do
      ids = Array.new(10_000) { described_class.generate }
      expect(ids.uniq.size).to eq(10_000)
    end

    it "generates ids that sort in creation order" do
      # The whole point of v7 over v4 — lexical sort must match creation order,
      # including for the thousands of ids minted inside a single millisecond.
      ids = Array.new(5_000) { described_class.generate }
      expect(ids).to eq(ids.sort)
    end

    it "stays monotonic across threads" do
      ids = Queue.new
      threads = 8.times.map do
        Thread.new { 500.times { ids << described_class.generate } }
      end
      threads.each(&:join)

      collected = []
      collected << ids.pop until ids.empty?

      expect(collected.uniq.size).to eq(4_000)
    end
  end
end
