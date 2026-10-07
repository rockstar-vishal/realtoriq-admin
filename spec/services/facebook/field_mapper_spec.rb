# frozen_string_literal: true

require "rails_helper"

RSpec.describe Facebook::FieldMapper do
  describe ".apply" do
    it "joins first and last name and keeps a non-Indian mobile" do
      result = described_class.apply(
        field_data: { "first_name" => "Rhea", "last_name" => "Kapoor", "phone_number" => "+1 415 555 2671" },
        mappings: {}
      )

      expect(result.name).to eq("Rhea Kapoor")
      expect(result.mobile).to eq("+14155552671")
      expect(result.mobile_invalid).to be false
    end

    it "marks a junk mobile invalid and drops a bad alternate number" do
      result = described_class.apply(
        field_data: { "phone_number" => "123", "alt" => "nope", "note" => "Sea view" },
        mappings: { "phone_number" => "mobile", "alt" => "alt_mobile", "note" => "notes" },
        questions: [ { "key" => "note", "label" => "View" } ]
      )

      expect(result.mobile).to be_nil
      expect(result.mobile_invalid).to be true
      expect(result.alt_mobile).to be_nil
      expect(result.notes).to eq("View: Sea view")
    end

    it "uses an explicit name mapping instead of the standard fields" do
      result = described_class.apply(
        field_data: { "full_name" => "Ignored", "custom_name" => "Asha" },
        mappings: { "custom_name" => "name", "full_name" => "ignore" }
      )

      expect(result.name).to eq("Asha")
    end
  end

  describe ".sanitize_mappings" do
    it "drops unknown targets" do
      expect(described_class.sanitize_mappings("q" => "detail:budget", "n" => "name")).to eq("n" => "name")
    end
  end
end
