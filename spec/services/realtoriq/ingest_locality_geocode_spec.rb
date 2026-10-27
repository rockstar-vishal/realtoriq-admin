# frozen_string_literal: true

require "rails_helper"

RSpec.describe "LaunchIQ locality centre lookup" do
  let!(:two_bhk) { create(:typology, name: "2 BHK", code: "2_bhk", bedrooms: 2) }
  let!(:ahmedabad) { create(:city, name: "Ahmedabad", state: "Gujarat") }

  def payload(overrides = {})
    {
      event: "upsert",
      pushed_at: "2026-10-28T06:00:00Z",
      project_code: "PRSHELA01",
      project_name: "Tapovan Amour",
      developer_name: "Tapovan",
      company_code: "CL00A1B2C3",
      rera_number: "P51800000099",
      possession_on: "2028-06-30",
      city: "Ahmedabad",
      locality: "Shela",
      rm_name: "Asha Rao",
      rm_contact: "9876543210",
      unit_types: [
        { label: "2 BHK", typology_name: "2BHK", price_min: 8_000_000 }
      ]
    }.merge(overrides)
  end

  it "enqueues one lookup when the share creates the locality" do
    result = nil
    expect {
      result = Realtoriq::IngestProject.call(payload)
    }.to have_enqueued_job(Localities::GeocodeCenterJob).once

    expect(result).to be_ok
    shela = Locality.find_by!(name: "Shela", city: ahmedabad)
    expect(Localities::GeocodeCenterJob).to have_been_enqueued.with(shela.id)
  end

  it "enqueues nothing for a locality that already exists" do
    create(:locality, city: ahmedabad, name: "Shela")

    expect {
      result = Realtoriq::IngestProject.call(payload)
      expect(result).to be_ok
    }.not_to have_enqueued_job(Localities::GeocodeCenterJob)
  end

  it "enqueues nothing when the share rolls back" do
    allow_any_instance_of(Project).to receive(:save!).and_raise(ActiveRecord::RecordInvalid.new(Project.new))

    result = nil
    expect {
      result = Realtoriq::IngestProject.call(payload)
    }.not_to have_enqueued_job(Localities::GeocodeCenterJob)

    expect(result).not_to be_ok
    expect(Locality.find_by(name: "Shela")).to be_nil
  end
end
