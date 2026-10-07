# frozen_string_literal: true

require "rails_helper"

RSpec.describe TrainingNote do
  let(:firm) { create(:firm) }
  let(:user) { create(:user, firm:) }
  let(:training) { create(:training, :active) }

  it "is firm-scoped, so another firm never reads it" do
    create(:training_note, user:, training:, body: "mine")

    Current.firm = firm
    expect(described_class.count).to eq(1)

    Current.firm = create(:firm)
    expect(described_class.count).to eq(0)
  end

  it "refuses a note whose user belongs to another firm" do
    outsider = create(:user, firm: create(:firm))

    note = build(:training_note, firm:, user: outsider, training:)

    expect(note).not_to be_valid
    expect(note.errors[:user_id].first).to include("isn't one of this firm's records")
  end

  it "keeps one note per broker per training" do
    create(:training_note, user:, training:)

    second = build(:training_note, user:, training:, firm:)

    expect(second).not_to be_valid
  end

  it "lets two brokers in the same firm each keep their own" do
    colleague = create(:user, firm:)
    create(:training_note, user:, training:)

    expect(build(:training_note, user: colleague, training:, firm:)).to be_valid
  end

  it "caps the body" do
    expect(build(:training_note, user:, training:, firm:, body: "x" * 20_001)).not_to be_valid
  end
end
