# frozen_string_literal: true

require "rails_helper"

RSpec.describe Facebook::FormSyncer do
  let(:firm) { create(:firm) }
  let(:page) { create(:facebook_page, firm:, subscribed: true, status: "active") }
  let(:client) { instance_double(Facebook::GraphApiClient) }

  before { Current.firm = firm }

  it "still renames a form whose lead source was turned off" do
    source = create(:lead_source, active: true)
    form = create(:facebook_lead_form, firm:, facebook_page: page, lead_source: source, form_name: "Keep me")
    source.update!(active: false)
    allow(Facebook::GraphApiClient).to receive(:new).and_return(client)
    allow(client).to receive(:list_lead_forms).and_return([
      { form_id: form.form_id, form_name: "Renamed", status: "ACTIVE", questions: [] }
    ])

    result = described_class.sync_page!(page)

    expect(result).to be_success
    expect(form.reload.form_name).to eq("Renamed")
    expect(page.reload.form_catalog.first["form_name"]).to eq("Renamed")
  end

  it "refreshes a form mapped to a mixed project that has no category" do
    home = create(:typology, name: "2 BHK", code: "2_bhk")
    shop = create(:typology, name: "Shop", code: "shop", category: "commercial")
    mixed = create(:project, firm:)
    create(:project_typology, project: mixed, typology: home)
    create(:project_typology, project: mixed, typology: shop, starting_price: 4_000_000)
    form = create(:facebook_lead_form, firm:, facebook_page: page, project: mixed, category: nil,
      form_name: "Old", questions: [], meta_status: "ACTIVE", active: true)
    allow(Facebook::GraphApiClient).to receive(:new).and_return(client)
    allow(client).to receive(:list_lead_forms).and_return([
      {
        form_id: form.form_id, form_name: "Renamed", status: "PAUSED",
        questions: [ { key: "full_name", label: "Full name", type: "FULL_NAME" } ]
      }
    ])

    result = described_class.sync_page!(page)

    expect(result).to be_success
    form.reload
    expect(form.form_name).to eq("Renamed")
    expect(form.meta_status).to eq("PAUSED")
    expect(form.active).to be(false)
    expect(form.questions).to include("key" => "full_name", "label" => "Full name", "type" => "FULL_NAME")
    expect(form.category).to be_nil
  end
end
