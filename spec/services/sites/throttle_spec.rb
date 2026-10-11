# frozen_string_literal: true

require "rails_helper"

RSpec.describe Sites::Throttle do
  it "refuses a body with no declared length" do
    request = instance_double(ActionDispatch::Request, content_length: nil)

    expect(described_class.body_ok?(request)).to be(false)
  end

  it "refuses a body over the cap" do
    request = instance_double(ActionDispatch::Request, content_length: 5.kilobytes)

    expect(described_class.body_ok?(request)).to be(false)
  end
end
