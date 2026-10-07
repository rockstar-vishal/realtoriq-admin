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
end
