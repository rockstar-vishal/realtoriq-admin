# frozen_string_literal: true

require "rails_helper"

RSpec.describe "India pins in matching" do
  let(:firm) { create(:firm) }
  let(:ahmedabad) { create(:city, name: "Ahmedabad", state: "Gujarat") }
  let(:shela) { create(:locality, city: ahmedabad, name: "Shela", lat: 23.01, lng: 72.46) }
  let(:status) { create(:lead_status, :new_lead) }
  let(:typology) { create(:typology, name: "2 BHK") }
  let(:property_type) { create(:property_type, name: "Under construction") }
  let(:builder) { create(:builder, firm: nil) }

  before { Current.firm = firm }
  after { Current.reset }

  def shifted(north_m)
    lat, lng = Inventory::Geo.offset(shela.lat.to_f, shela.lng.to_f, north_m:)
    { lat:, lng: }
  end

  def listing_args(point)
    {
      lat: point[:lat], lng: point[:lng],
      locality_lat: shela.lat, locality_lng: shela.lng
    }
  end

  it "uses a Shela pin within 20 km for distance and as an anchor" do
    near = shifted(5_000)
    listed = Inventory::Geo.listing_point(**listing_args(near))
    anchor = Inventory::Geo.own_pin(**listing_args(near))

    expect(listed[:lat]).to be_within(0.000_01).of(near[:lat])
    expect(listed[:lng]).to be_within(0.000_01).of(near[:lng])
    expect(anchor).to eq(listed)
    expect(Inventory::Geo.distance_m(listed[:lat], listed[:lng], shela.lat, shela.lng)).to be_within(50).of(5_000)

    project = create(:project, firm:, city: ahmedabad, locality: shela, builder:, name: "Tapovan Amour",
      lat: near[:lat], lng: near[:lng], possession_on: Date.new(2028, 6, 1), possession_label: nil)
    create(:project_typology, project:, typology:)
    lead = create(:lead, firm:, lead_status: status, property_type:, name: "Asha")
    lead.typologies << typology
    lead.lead_projects.create!(project:, firm:)

    picked = Inventory::LeadAnchors.for([ lead ])[lead.id]
    expect(picked.map(&:listing_id)).to eq([ project.id ])
    expect(picked.first.lat).to be_within(0.000_01).of(near[:lat])
  end

  it "uses the locality centre when the pin is 30 km away" do
    far = shifted(30_000)
    listed = Inventory::Geo.listing_point(**listing_args(far))

    expect(listed[:lat]).to be_within(0.000_01).of(shela.lat.to_f)
    expect(listed[:lng]).to be_within(0.000_01).of(shela.lng.to_f)
    expect(Inventory::Geo.own_pin(**listing_args(far))).to be_nil
  end

  it "anchors a lead whose place is in Ahmedabad" do
    lead = create(:lead, firm:, lead_status: status, property_type:, name: "Asha",
      near_lat: 23.03, near_lng: 72.58, near_label: "Office")

    anchors = Inventory::LeadAnchors.for([ lead ])[lead.id]

    expect(anchors.map(&:kind)).to eq([ "placed" ])
    expect(anchors.first.name).to eq("Office")
    expect(anchors.first.lat).to be_within(0.000_01).of(23.03)
    expect(anchors.first.lng).to be_within(0.000_01).of(72.58)
  end
end
