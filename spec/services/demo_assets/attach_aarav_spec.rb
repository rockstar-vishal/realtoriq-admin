# frozen_string_literal: true

require "rails_helper"

RSpec.describe DemoAssets::AttachAarav do
  it "attaches the project photos, the ladder and the matching listing" do
    city = create(:city, name: "Mumbai", state: "Maharashtra")
    locality = create(:locality, city:, name: "Andheri West")
    typology = create(:typology, name: "2 BHK")
    firm = create(:firm, name: "Aarav Realty")
    project = create(:project, firm:, city:, name: "Palm Court Residences")
    building = create(:building, firm:, city:, locality:, name: "Palm Court")
    property = create(:property, firm:, building:, typology:, listing_for: "sale", price: 18_000_000)

    dir = Rails.root.join("tmp/aarav-attach-spec")
    FileUtils.rm_rf(dir)
    FileUtils.mkdir_p(dir)
    dir.join("palm-1.jpg").write("photo-one")
    dir.join("palm-2.jpg").write("photo-two")
    dir.join("ladder.png").write("ladder")
    dir.join("resale.jpg").write("listing")

    described_class.call(
      dir:, firm:,
      projects: { "Palm Court Residences" => { photos: %w[palm-1.jpg palm-2.jpg], ladder: "ladder.png" } },
      listings: { "resale.jpg" => { listing_for: "sale", locality: "Andheri West", typology: "2 BHK", price: 18_000_000 } }
    )

    Current.set(firm:) do
      expect(project.reload.photos.count).to eq(2)
      expect(project.brokerage_ladder).to be_attached
      expect(property.reload.photos.count).to eq(1)
      expect(project.photos.blobs.map { |blob| blob.filename.to_s }).to contain_exactly("palm-1.jpg", "palm-2.jpg")
    end
  end
end
