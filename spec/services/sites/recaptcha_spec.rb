# frozen_string_literal: true

require "rails_helper"

RSpec.describe Sites::Recaptcha do
  before do
    allow(Rails).to receive(:env).and_return(ActiveSupport::StringInquirer.new("production"))
    allow(Realtoriq::Credentials).to receive(:recaptcha_secret).and_return("test-secret")
  end

  def http_returning(payload)
    response = instance_double(Net::HTTPOK, body: payload.to_json)
    allow(response).to receive(:is_a?).with(Net::HTTPSuccess).and_return(true)
    http = instance_double(Net::HTTP)
    allow(http).to receive(:request).and_return(response)
    allow(Net::HTTP).to receive(:start).and_yield(http)
  end

  it "accepts a token minted for this host" do
    http_returning("success" => true, "hostname" => "cp-aarav.realtoriq.kgen.tech")

    expect(
      described_class.accepted?("tok", remote_ip: "1.1.1.1", hostname: "cp-aarav.realtoriq.kgen.tech")
    ).to be(true)
  end

  it "refuses a token minted for a different host" do
    http_returning("success" => true, "hostname" => "evil.example")

    expect(
      described_class.accepted?("tok", remote_ip: "1.1.1.1", hostname: "cp-aarav.realtoriq.kgen.tech")
    ).to be(false)
  end

  it "refuses when Google cannot be reached" do
    allow(Net::HTTP).to receive(:start).and_raise(Net::OpenTimeout)

    expect(
      described_class.accepted?("tok", remote_ip: "1.1.1.1", hostname: "cp-aarav.realtoriq.kgen.tech")
    ).to be(false)
  end
end
