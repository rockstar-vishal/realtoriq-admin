# frozen_string_literal: true

require "rails_helper"

RSpec.describe OneTimeCode do
  describe ".issue!" do
    it "returns the plaintext once and stores only a digest" do
      record, code = described_class.issue!(purpose: "login", destination: "+919820144210")

      expect(code).to match(/\A\d{6}\z/)
      expect(record.code_digest).not_to include(code)
      expect(record.reload.attributes.values.map(&:to_s)).not_to include(code)
    end

    it "zero-pads so every code is six digits" do
      allow(SecureRandom).to receive(:random_number).and_return(42)

      _record, code = described_class.issue!(purpose: "login", destination: "x@example.com")

      expect(code).to eq("000042")
    end

    it "expires in ten minutes by default" do
      record, _ = described_class.issue!(purpose: "login", destination: "+919820144210")

      expect(record.expires_at).to be_within(5.seconds).of(10.minutes.from_now)
    end
  end

  describe "a fixed code" do
    around do |example|
      original = Rails.configuration.x.otp_fixed_code
      Rails.configuration.x.otp_fixed_code = "888888"
      example.run
      Rails.configuration.x.otp_fixed_code = original
    end

    it "issues the configured code instead of a random one" do
      _record, code = described_class.issue!(purpose: "login", destination: "+919820144210")

      expect(code).to eq("888888")
    end

    it "is still stored only as a digest" do
      record, = described_class.issue!(purpose: "login", destination: "+919820144210")

      expect(record.code_digest).not_to include("888888")
    end

    it "still expires" do
      record, code = described_class.issue!(purpose: "login", destination: "+919820144210")
      record.update!(expires_at: 1.second.ago)

      expect(record.verify(code)).to be(false)
    end

    it "still burns after one use" do
      record, code = described_class.issue!(purpose: "login", destination: "+919820144210")

      expect(record.verify(code)).to be(true)
      expect(record.verify(code)).to be(false)
    end

    it "still rejects any other code" do
      record, = described_class.issue!(purpose: "login", destination: "+919820144210")

      expect(record.verify("123456")).to be(false)
    end

    it "keeps the initializer's hardcoded length in step with the model" do
      # The boot guard can't reference OneTimeCode (initializers run before
      # autoloading), so it hardcodes 6. This fails if the model ever changes.
      expect(described_class::CODE_LENGTH).to eq(6)
    end

    it "is off by default in the test environment, so specs exercise the real thing" do
      # Guards against someone switching test to fixed codes and quietly
      # hollowing out every auth spec in the suite.
      Rails.configuration.x.otp_fixed_code = nil

      codes = Array.new(20) { described_class.issue!(purpose: "login", destination: "x").last }

      expect(codes.uniq.size).to be > 1
    end
  end

  describe "#verify" do
    let!(:issued) { described_class.issue!(purpose: "login", destination: "+919820144210") }
    let(:record) { issued.first }
    let(:code) { issued.last }

    it "accepts the right code" do
      expect(record.verify(code)).to be(true)
    end

    it "consumes the code so it cannot be replayed" do
      expect(record.verify(code)).to be(true)
      expect(record.verify(code)).to be(false)
    end

    it "rejects a wrong code and counts the attempt" do
      expect(record.verify("000000")).to be(false)
      expect(record.reload.attempts).to eq(1)
    end

    it "refuses once the attempt budget is spent" do
      record.max_attempts.times { record.verify("000000") }

      # Even the correct code is refused now — the record is burned.
      expect(record.verify(code)).to be(false)
    end

    it "refuses an expired code" do
      record.update!(expires_at: 1.second.ago)

      expect(record.verify(code)).to be(false)
    end
  end

  describe ".purge_expired" do
    it "removes codes well past their window and leaves live ones" do
      old, = described_class.issue!(purpose: "login", destination: "a@example.com")
      old.update!(expires_at: 3.days.ago)
      live, = described_class.issue!(purpose: "login", destination: "b@example.com")

      described_class.purge_expired

      expect(described_class.exists?(old.id)).to be(false)
      expect(described_class.exists?(live.id)).to be(true)
    end
  end
end
