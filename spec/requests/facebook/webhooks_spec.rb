# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Facebook leadgen webhook" do
  let(:secret) { "app-secret" }
  let(:verify_token) { "verify-me" }

  before do
    allow(Rails.application.credentials).to receive(:dig).and_wrap_original do |method, *args|
      case args
      when [ :facebook, :app_secret ] then secret
      when [ :facebook, :verify_token ] then verify_token
      else method.call(*args)
      end
    end
  end

  def post_lead(payload, signature: :valid)
    body = payload.is_a?(String) ? payload : JSON.generate(payload)
    header = case signature
    when :valid then "sha256=#{OpenSSL::HMAC.hexdigest('SHA256', secret, body)}"
    when :blank then nil
    else signature
    end
    headers = { "CONTENT_TYPE" => "application/json" }
    headers["X-Hub-Signature-256"] = header if header
    post "/facebook/webhook", params: body, headers:
  end

  describe "GET /facebook/webhook" do
    it "returns the challenge when the verify token matches" do
      get "/facebook/webhook", params: {
        "hub.mode" => "subscribe",
        "hub.verify_token" => verify_token,
        "hub.challenge" => "challenge-1"
      }

      expect(response).to have_http_status(:ok)
      expect(response.body).to eq("challenge-1")
      expect(response.media_type).to eq("text/plain")
    end

    it "refuses a wrong token without raising on a short value" do
      get "/facebook/webhook", params: {
        "hub.mode" => "subscribe",
        "hub.verify_token" => "no",
        "hub.challenge" => "challenge-1"
      }

      expect(response).to have_http_status(:forbidden)
    end
  end

  describe "POST /facebook/webhook" do
    let(:firm) { create(:firm) }
    let(:page) { create(:facebook_page, firm:, page_id: "page-9", subscribed: true, status: "active") }

    it "refuses a bad signature and a body that is not JSON" do
      post_lead({ entry: [] }, signature: "sha256=abc")
      expect(response).to have_http_status(:unauthorized)

      post_lead("not-json")
      expect(response).to have_http_status(:bad_request)
    end

    it "refuses a body over 1MB" do
      post_lead({ entry: [] }.to_json + ("x" * 1.megabyte))
      expect(response).to have_http_status(:content_too_large)
    end

    it "stores a pending import for a page one firm owns and ignores a repeat" do
      page
      payload = {
        entry: [ {
          changes: [ {
            field: "leadgen",
            value: { leadgen_id: "lg-1", page_id: "page-9", form_id: "form-9" }
          } ]
        } ]
      }

      expect { post_lead(payload) }.to change { FacebookLeadImport.across_firms.count }.by(1)
      expect(response).to have_http_status(:ok)
      import = FacebookLeadImport.across_firms.find_by!(leadgen_id: "lg-1")
      expect(Facebook::ProcessLeadJob).to have_been_enqueued.with(firm.id, import.id)

      expect { post_lead(payload) }.not_to change { FacebookLeadImport.across_firms.count }
      expect(Facebook::ProcessLeadJob).to have_been_enqueued.once
    end

    it "drops an unknown page" do
      post_lead({ entry: [ { changes: [ { field: "leadgen", value: { leadgen_id: "lg-x", page_id: "missing" } } ] } ] })
      expect(response).to have_http_status(:ok)
      expect(FacebookLeadImport.across_firms.count).to eq(0)
    end

    it "routes a known form to the firm that owns it" do
      form = create(:facebook_lead_form, firm:, facebook_page: page, form_id: "owned-form")

      post_lead({ entry: [ {
        changes: [ {
          field: "leadgen",
          value: { leadgen_id: "lg-owned", page_id: page.page_id, form_id: "owned-form" }
        } ]
      } ] })

      import = FacebookLeadImport.across_firms.find_by!(leadgen_id: "lg-owned")
      expect(import.firm_id).to eq(firm.id)
      expect(import.facebook_lead_form_id).to eq(form.id)
    end

    it "ignores changes that are not leadgen" do
      page
      post_lead({ entry: [ { changes: [ { field: "feed", value: { leadgen_id: "lg-feed", page_id: "page-9" } } ] } ] })

      expect(response).to have_http_status(:ok)
      expect(FacebookLeadImport.across_firms.count).to eq(0)
    end

    it "returns 500 when storing the import raises" do
      page
      allow(Facebook::RouteLead).to receive(:call).and_raise(ActiveRecord::StatementInvalid, "db down")

      post_lead({ entry: [ { changes: [ { field: "leadgen", value: { leadgen_id: "lg-1", page_id: "page-9" } } ] } ] })
      expect(response).to have_http_status(:internal_server_error)
    end
  end
end
