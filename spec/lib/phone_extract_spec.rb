# frozen_string_literal: true

require "rails_helper"

RSpec.describe Phone do
  describe ".extract_indian_mobile" do
    {
      "9876543210" => "+919876543210",
      "09876543210" => "+919876543210",
      "+91 98765 43210" => "+919876543210",
      "91-9876543210" => "+919876543210",
      "0091 9876543210" => "+919876543210",
      "+91 (98765) 43210" => "+919876543210",
      "https://wa.me/919876543210" => "+919876543210",
      "please call 9876543210 tomorrow" => "+919876543210",
      "9876543210.0" => "+919876543210",
      "'9876543210" => "+919876543210",
      "9876543210 ext 12" => "+919876543210",
      "9876543210 / 9876543210" => "+919876543210"
    }.each do |raw, expected|
      it "reads #{raw.inspect}" do
        expect(Phone.extract_indian_mobile(raw).mobile).to eq(expected)
      end
    end

    it "rejects a landline" do
      expect(Phone.extract_indian_mobile("02226123456").error).to eq(Phone::NOT_A_MOBILE)
    end

    it "rejects a number that does not start with 6-9" do
      expect(Phone.extract_indian_mobile("1234567890").error).to eq(Phone::NOT_A_MOBILE)
    end

    it "rejects two mobiles in one cell" do
      result = Phone.extract_indian_mobile("9876543210 / 9988776655")
      expect(result.error).to eq(Phone::TOO_MANY_NUMBERS)
    end

    it "rejects Excel scientific notation" do
      result = Phone.extract_indian_mobile("9.87654E+09")
      expect(result.error).to eq(Phone::SCIENTIFIC_NUMBER)
    end

    it "rejects a blank cell" do
      expect(Phone.extract_indian_mobile("  ").error).to eq(Phone::NUMBER_REQUIRED)
    end

    it "leaves lead normalisation alone" do
      expect(Phone.normalise("09820144210")).to eq("+919820144210")
      expect(Phone.normalise("+1 415 555 2671")).to eq("+14155552671")
    end
  end
end
