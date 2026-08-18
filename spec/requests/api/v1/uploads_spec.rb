# frozen_string_literal: true

require "rails_helper"

RSpec.describe "API v1 uploads" do
  let(:plan) { create(:plan) }
  let(:firm) { create(:firm, status: :active) }
  let!(:subscription) { create(:subscription, firm:, plan:) }
  let!(:user) { create(:user, :super_admin, firm:) }

  def auth_headers
    post "/api/v1/auth/otp", params: { mobile: user.mobile }, as: :json
    request_id = response.parsed_body["request_id"]
    post "/api/v1/auth/verify", params: { request_id:, code: deliverer.last.code }, as: :json
    { "Authorization" => "Bearer #{response.parsed_body['access_token']}" }
  end

  def ticket_for(overrides = {})
    post "/api/v1/uploads", params: {
      purpose: "project_brochure", filename: "brochure.pdf",
      byte_size: 1.megabyte, checksum: "XrY7u+Ae7tCTyyK7j1rNww==",
      content_type: "application/pdf"
    }.merge(overrides), headers: auth_headers, as: :json
  end

  describe "POST /uploads" do
    it "issues a direct-upload ticket" do
      ticket_for

      body = response.parsed_body
      expect(response).to have_http_status(:created)
      expect(body["signed_id"]).to be_present
      expect(body.dig("direct_upload", "url")).to be_present
      expect(body.dig("direct_upload", "headers")).to be_a(Hash)
    end

    it "records the tenant against the blob, so an orphan can be traced" do
      ticket_for

      blob = ActiveStorage::Blob.find_signed!(response.parsed_body["signed_id"])
      expect(blob.metadata["firm_id"]).to eq(firm.id)
      expect(blob.metadata["purpose"]).to eq("project_brochure")
    end

    it "requires authentication" do
      post "/api/v1/uploads", params: { purpose: "firm_logo" }, as: :json

      expect(response).to have_http_status(:unauthorized)
    end
  end

  describe "limits" do
    it "refuses a file over the purpose's size cap" do
      ticket_for(byte_size: 6.megabytes)

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body.dig("error", "code")).to eq("file_too_large")
    end

    it "refuses a content type the purpose doesn't accept" do
      ticket_for(content_type: "image/png", filename: "nope.png")

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body.dig("error", "code")).to eq("unsupported_type")
    end

    it "applies each purpose's own cap" do
      # Booking documents are capped at 2 MB on the design's own screen, while
      # a brochure of the same size is fine.
      ticket_for(purpose: "booking_document", byte_size: 3.megabytes)

      expect(response.parsed_body.dig("error", "code")).to eq("file_too_large")
    end

    it "rejects an unknown purpose" do
      ticket_for(purpose: "something_else")

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body.dig("error", "code")).to eq("unknown_purpose")
    end

    it "rejects a missing size" do
      ticket_for(byte_size: 0)

      expect(response.parsed_body.dig("error", "code")).to eq("invalid_size")
    end
  end

  describe "Rails' own direct-upload endpoint" do
    it "is shadowed, so /api/v1/uploads is the only way to get a ticket" do
      # It sits outside our JWT auth and enforces none of the per-purpose
      # limits above, so leaving it mounted would make all of this optional.
      post "/rails/active_storage/direct_uploads", params: {
        blob: {
          filename: "anything.pdf", byte_size: 999_999_999,
          checksum: "XrY7u+Ae7tCTyyK7j1rNww==", content_type: "application/pdf"
        }
      }, as: :json

      expect(response).to have_http_status(:not_found)
    end
  end

  describe UploadPurpose do
    it "documents every purpose with a cap and an allow-list" do
      described_class.catalogue.each do |entry|
        expect(entry[:max_bytes]).to be_positive
        expect(entry[:content_types]).not_to be_empty
      end
    end
  end
end
