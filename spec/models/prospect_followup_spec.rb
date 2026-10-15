# frozen_string_literal: true

require "rails_helper"

RSpec.describe ProspectFollowup do
  it "prefixes outcome scopes so not_interested does not clash with interested" do
    expect(described_class).to respond_to(:outcome_not_interested)
    expect(described_class).to respond_to(:outcome_interested)
    expect(described_class).not_to respond_to(:not_interested)
  end
end
