# frozen_string_literal: true

require "rails_helper"

RSpec.describe Sites::PagesHelper, type: :helper do
  describe "#about_parts" do
    it "is nil when there is nothing to show" do
      expect(helper.about_parts(nil)).to be_nil
      expect(helper.about_parts("  \n ")).to be_nil
      expect(helper.about_parts("About us")).to be_nil
    end

    it "leads with a short first line and keeps the rest" do
      parts = helper.about_parts("A family brokerage in Pune.\nWe help buyers and tenants.")

      expect(parts[:lead]).to eq("A family brokerage in Pune.")
      expect(parts[:blocks]).to eq([ [ :text, "We help buyers and tenants." ] ])
      expect(parts[:fold]).to be_nil
    end

    it "takes the first sentence of a long first line, past abbreviations" do
      text = "Aarav Realty Pvt. Ltd. was founded by Mr. Rajesh Mehta in 2004 in Andheri West. " \
        "Since then we have helped many families find homes across Mumbai, from studios to sea-facing flats."
      parts = helper.about_parts(text)

      expect(parts[:lead]).to eq("Aarav Realty Pvt. Ltd. was founded by Mr. Rajesh Mehta in 2004 in Andheri West.")
      expect(parts[:blocks].first.last).to start_with("Since then")
    end

    it "drops a repeated heading and turns bullet lines into a list" do
      text = "About Us:\nTrusted brokers in Powai.\r\n\r\nWhy us:\n• 15 years in Powai\n- Home loan help\n✅ Weekend visits"
      parts = helper.about_parts(text)

      expect(parts[:lead]).to eq("Trusted brokers in Powai.")
      expect(parts[:blocks]).to eq([
        [ :text, "Why us:" ],
        [ :list, [ "15 years in Powai", "Home loan help", "Weekend visits" ] ]
      ])
    end

    it "folds long text on a phone, and very long text everywhere" do
      expect(helper.about_parts("Lead line here.\n#{'word ' * 120}")[:fold]).to eq(:phone)
      expect(helper.about_parts("Lead line here.\n#{'word ' * 300}")[:fold]).to eq(:all)
    end

    it "leaves escaping to the template" do
      expect(helper.about_parts("<b>Hi</b> there, friends")[:lead]).to eq("<b>Hi</b> there, friends")
    end
  end

  describe "#site_areas" do
    it "lists localities, the most listed first, without blanks" do
      areas = helper.site_areas(
        [ { locality: "Powai" }, { locality: "Kothrud" } ],
        [ { locality: "Kothrud" }, { locality: nil }, { locality: "" } ]
      )

      expect(areas).to eq([ "Kothrud", "Powai" ])
    end
  end
end
