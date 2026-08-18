# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Admin masters" do
  before { sign_in_admin }

  describe "cities" do
    it "lists them" do
      create(:city, name: "Navi Mumbai", state: "Maharashtra")

      get admin_masters_cities_path

      expect(response.body).to include("Navi Mumbai")
    end

    it "creates one and derives the state code" do
      post admin_masters_cities_path, params: { city: { name: "Pune", state: "Maharashtra" } }

      expect(City.find_by(name: "Pune").state_code).to eq("MH")
    end

    it "is addressed by slug, not id" do
      city = create(:city, name: "Thane", state: "Maharashtra")

      patch admin_masters_city_path(city), params: { city: { name: "Thane City" } }

      expect(city.reload.name).to eq("Thane City")
    end

    it "refuses to delete a city that still has localities" do
      city = create(:city)
      create(:locality, city:)

      delete admin_masters_city_path(city)

      expect(City.exists?(city.id)).to be(true)
      expect(flash[:alert]).to be_present
    end

    it "re-renders with errors when invalid" do
      post admin_masters_cities_path, params: { city: { name: "", state: "" } }

      expect(response).to have_http_status(:unprocessable_content)
    end
  end

  describe "lead statuses" do
    it "keeps the report flags that make the dead-leads report possible" do
      post admin_masters_lead_statuses_path,
        params: { lead_status: { name: "Lost", is_dead: "1", sort_order: 9 } }

      status = LeadStatus.find_by(name: "Lost")
      expect(status).to be_is_dead
      expect(status.code).to eq("lost")
    end
  end

  describe "localities" do
    it "creates one against its city" do
      city = create(:city)

      post admin_masters_localities_path,
        params: { locality: { name: "Kharghar", city_id: city.id, pincode: "410210" } }

      expect(Locality.find_by(name: "Kharghar").city).to eq(city)
    end
  end

  describe "typologies" do
    it "stores half configurations" do
      post admin_masters_typologies_path, params: { typology: { name: "2.5 BHK", bedrooms: "2.5" } }

      expect(Typology.find_by(name: "2.5 BHK").bedrooms).to eq(2.5)
    end
  end

  describe "access" do
    it "requires an admin" do
      delete admin_session_path

      get admin_masters_cities_path

      expect(response).to redirect_to(new_admin_session_path)
    end
  end
end
