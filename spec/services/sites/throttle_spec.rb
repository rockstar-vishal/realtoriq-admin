# frozen_string_literal: true

require "rails_helper"

RSpec.describe Sites::Throttle do
  it "refuses a body with no declared length" do
    request = instance_double(ActionDispatch::Request, content_length: nil)

    expect(described_class.body_ok?(request)).to be(false)
  end

  it "refuses a body over the cap" do
    request = instance_double(ActionDispatch::Request, content_length: described_class::BODY_BYTES + 1)

    expect(described_class.body_ok?(request)).to be(false)
  end

  it "allows a long message written in an Indic script" do
    message = "नमस्ते " * 70
    encoded = Rack::Utils.build_query("message" => message, "g-recaptcha-response" => "t" * 1_500)

    expect(encoded.bytesize).to be > 4.kilobytes
    request = instance_double(ActionDispatch::Request, content_length: encoded.bytesize)
    expect(described_class.body_ok?(request)).to be(true)
  end
end
