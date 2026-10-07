# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Facebook Lead Ads models" do
  let(:firm) { create(:firm) }
  let(:other_firm) { create(:firm) }

  before { Current.firm = firm }

  describe FacebookLeadForm do
    let(:page) { create(:facebook_page, firm:) }

    it "refuses a project and a property together" do
      form = build(
        :facebook_lead_form,
        firm:,
        facebook_page: page,
        project: create(:project, firm:),
        property: create(:property, firm:)
      )

      expect(form).not_to be_valid
    end

    it "refuses another firm's project, property or user" do
      form = build(:facebook_lead_form, firm:, facebook_page: page)
      form.project = create(:project, firm: other_firm)
      expect(form).not_to be_valid

      form.project = nil
      form.property = create(:property, firm: other_firm)
      expect(form).not_to be_valid

      form.property = nil
      form.assigned_user = create(:user, firm: other_firm)
      expect(form).not_to be_valid
    end

    it "accepts a marketplace project" do
      catalog = Current.set(firm: nil, firm_scope_bypassed: true) do
        create(:project, :catalog, firm: nil, name: "Harbour One",
          builder: create(:builder, firm: nil), city: create(:city))
      end
      Current.firm = firm

      form = build(:facebook_lead_form, firm:, facebook_page: page, project: catalog)

      expect(form).to be_valid
    end

    it "keeps form_id unique across firms" do
      create(:facebook_lead_form, firm:, facebook_page: page, form_id: "shared-form")
      Current.firm = other_firm
      other_page = create(:facebook_page, firm: other_firm)
      duplicate = build(:facebook_lead_form, firm: other_firm, facebook_page: other_page, form_id: "shared-form")

      expect(duplicate).not_to be_valid
      expect(duplicate.errors[:form_id]).to include("has already been taken")
    end
  end

  describe FacebookPage do
    it "keeps page_id unique across firms" do
      create(:facebook_page, firm:, page_id: "only-once")
      Current.firm = other_firm
      duplicate = build(:facebook_page, firm: other_firm, page_id: "only-once")

      expect(duplicate).not_to be_valid
      expect(duplicate.errors[:page_id]).to include("has already been taken")
    end
  end

  describe FacebookLeadImport do
    it "lets only one claim win" do
      import = create(:facebook_lead_import, firm:)
      first = described_class.find(import.id)
      second = described_class.find(import.id)

      expect([ first.claim!, second.claim! ].count(true)).to eq(1)
      expect(import.reload).to be_processing
    end
  end

  describe FacebookConnection do
    it "lets only the first invalidation win" do
      connection = create(:facebook_connection, firm:)
      first = described_class.find(connection.id)
      second = described_class.find(connection.id)

      expect(first.claim_invalid!(error_code: "190", message: "expired")).to be true
      expect(second.claim_invalid!(error_code: "190", message: "expired")).to be false
      expect(connection.reload).to be_connection_invalid
    end
  end

  describe "Firm#destroy!" do
    it "removes a firm that has every kind of Facebook row" do
      connection = create(:facebook_connection, firm:)
      page = create(:facebook_page, firm:, facebook_connection: connection)
      form = create(:facebook_lead_form, firm:, facebook_page: page, project: create(:project, firm:))
      create(:facebook_lead_import, firm:, facebook_page: page, facebook_lead_form: form, lead: create(:lead, firm:))
      create(:facebook_oauth_attempt, firm:, user: connection.connected_by_user)
      create(:facebook_import_alert_state, firm:)

      expect { firm.destroy! }.not_to raise_error
      expect(FacebookConnection.across_firms.where(firm_id: firm.id)).to be_empty
      expect(FacebookPage.across_firms.where(firm_id: firm.id)).to be_empty
      expect(FacebookLeadForm.across_firms.where(firm_id: firm.id)).to be_empty
      expect(FacebookLeadImport.across_firms.where(firm_id: firm.id)).to be_empty
    end
  end
end
