# frozen_string_literal: true

require "rails_helper"

RSpec.describe Form6::Classification do
  def typology(name, category)
    build(:typology, name:, category:, code: "#{name.parameterize(separator: '_')}_#{category}")
  end

  {
    [ "Residential plot", "land" ] => [ "Plot", "Others" ],
    [ "Commercial plot", "commercial" ] => [ "Plot", "Others" ],
    [ "Agricultural land", "land" ] => [ "Plot", "Others" ],
    [ "Shop", "commercial" ] => [ "Shop", "Commercial" ],
    [ "Showroom", "commercial" ] => [ "Shop", "Commercial" ],
    [ "Office", "commercial" ] => [ "Others", "Commercial" ],
    [ "Villa", "residential" ] => [ "Others", "Residential" ],
    [ "Row house", "residential" ] => [ "Others", "Residential" ],
    [ "2 BHK", "residential" ] => [ "Apartment", "Residential" ],
    [ "1 RK", "residential" ] => [ "Apartment", "Residential" ],
    [ "1RK", "residential" ] => [ "Apartment", "Residential" ],
    [ "Park", "residential" ] => [ "Others", "Residential" ],
    [ "Studio", "residential" ] => [ "Apartment", "Residential" ],
    [ "Penthouse", "residential" ] => [ "Apartment", "Residential" ]
  }.each do |(name, category), (unit, label)|
    it "classifies #{name} as #{unit} / #{label}" do
      row = typology(name, category)

      expect(described_class.unit_type(row)).to eq(unit)
      expect(described_class.category_label(row)).to eq(label)
    end
  end

  it "leaves both cells blank when the booking has no configuration" do
    expect(described_class.unit_type(nil)).to be_nil
    expect(described_class.category_label(nil)).to be_nil
  end
end
