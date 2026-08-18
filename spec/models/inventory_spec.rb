# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Inventory models" do
  let(:firm) { create(:firm) }

  before { Current.firm = firm }

  describe Project do
    describe "price and area bands" do
      it "derives them from the typologies rather than storing them" do
        # The design's index card reads "₹1.42–1.80 Cr" and "720–1,340 sqft".
        project = create(:project, firm:)
        create(:project_typology, project:, starting_price: 14_200_000, starting_carpet_sqft: 720)
        create(:project_typology, project:, starting_price: 18_000_000, starting_carpet_sqft: 1_340)

        expect(project.reload.price_band).to eq(from: 14_200_000, to: 18_000_000)
        expect(project.area_band).to eq(from: 720, to: 1_340)
      end

      it "is nil when nothing has been priced" do
        expect(create(:project, firm:).price_band).to be_nil
      end

      it "ignores typologies with no price" do
        project = create(:project, firm:)
        create(:project_typology, project:, starting_price: 9_000_000)
        create(:project_typology, project:, starting_price: nil)

        expect(project.reload.price_band).to eq(from: 9_000_000, to: 9_000_000)
      end
    end

    describe "possession" do
      it "accepts a label instead of a date, for a ready project" do
        project = build(:project, firm:, possession_on: nil, possession_label: "Ready")

        expect(project).to be_valid
        expect(project.possession_display).to eq("Ready")
      end

      it "requires one or the other" do
        expect(build(:project, firm:, possession_on: nil, possession_label: nil)).not_to be_valid
      end
    end

    describe "promotions" do
      it "is live when it has no end date" do
        expect(build(:project, firm:, promo_text: "Extra 1%", promo_ends_on: nil)).to be_promo_live
      end

      it "stops being live once the end date has passed" do
        project = build(:project, firm:, promo_text: "Extra 1%", promo_ends_on: 1.day.ago)

        expect(project).not_to be_promo_live
      end
    end

    describe "builders" do
      it "accepts a global builder" do
        expect(build(:project, firm:, builder: create(:builder, firm: nil))).to be_valid
      end

      it "accepts the firm's own" do
        expect(build(:project, firm:, builder: create(:builder, firm:))).to be_valid
      end

      it "refuses another firm's private builder" do
        # Allowing it would leak that the other firm's builder exists.
        stranger = create(:builder, firm: create(:firm))

        expect(build(:project, firm:, builder: stranger)).not_to be_valid
      end
    end

    describe "budget filtering" do
      it "matches a project when any typology starts inside the window" do
        cheap = create(:project, firm:)
        create(:project_typology, project: cheap, starting_price: 5_000_000)
        mixed = create(:project, firm:)
        create(:project_typology, project: mixed, starting_price: 5_000_000)
        create(:project_typology, project: mixed, starting_price: 25_000_000)

        found = described_class.budget_between(20_000_000, 30_000_000).pluck(:id)

        expect(found).to eq([ mixed.id ])
        expect(found).not_to include(cheap.id)
      end
    end
  end

  describe Building do
    it "refuses two buildings of the same name in one locality" do
      existing = create(:building, firm:)

      duplicate = build(:building, firm:, name: existing.name,
        city: existing.city, locality: existing.locality)

      expect(duplicate).not_to be_valid
    end

    it "allows the same name in a different locality" do
      existing = create(:building, firm:)
      elsewhere = create(:locality, city: existing.city)

      expect(build(:building, firm:, name: existing.name, city: existing.city, locality: elsewhere))
        .to be_valid
    end

    it "allows another firm the same name — buildings are firm-owned" do
      existing = create(:building, firm:)
      other = create(:firm)
      Current.firm = other

      expect(build(:building, firm: other, name: existing.name,
        city: existing.city, locality: existing.locality)).to be_valid
    end

    it "refuses a locality that isn't in the chosen city" do
      elsewhere = create(:locality, city: create(:city))

      expect(build(:building, firm:, locality: elsewhere)).not_to be_valid
    end

    it "will not be destroyed while it still holds listings" do
      building = create(:building, firm:)
      create(:property, firm:, building:)

      expect(building.destroy).to be(false)
      expect(building.errors[:base]).to be_present
    end
  end

  describe Property do
    it "titles itself the way the design's card reads" do
      building = create(:building, firm:)
      property = create(:property, firm:, building:,
        typology: create(:typology, name: "2 BHK"))

      expect(property.title).to eq("2 BHK in #{building.locality.name}")
    end

    it "derives the rate per sqft" do
      property = build(:property, firm:, price: 11_800_000, carpet_area_sqft: 690)

      expect(property.rate_per_sqft).to eq(17_101)
    end

    it "has no rate when the area is unknown" do
      expect(build(:property, firm:, carpet_area_sqft: nil).rate_per_sqft).to be_nil
    end

    it "treats price as monthly rent for a rental" do
      property = create(:property, firm:, listing_for: "rent", price: 52_000)

      expect(property).to be_rental
      expect(property.price).to eq(52_000)
    end

    it "rejects a floor band it doesn't recognise" do
      expect(build(:property, firm:, floor_band: "penthouse-ish")).not_to be_valid
    end
  end

  describe ProjectTypology do
    it "computes a rate per sqft" do
      typology = build(:project_typology, starting_price: 14_200_000, starting_carpet_sqft: 720)

      expect(typology.rate_per_sqft).to eq(19_722)
    end

    it "refuses the same typology twice on one project" do
      project = create(:project, firm:)
      typology = create(:typology)
      create(:project_typology, project:, typology:)

      expect(build(:project_typology, project:, typology:)).not_to be_valid
    end
  end
end
