# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Field demo firms" do
  let(:plan) { create(:plan) }
  let(:firm) { create(:firm, name: "Aarav Realty", status: :active, field_demo: true) }
  let!(:subscription) { create(:subscription, firm:, plan:) }
  let!(:owner) { create(:user, :super_admin, firm:) }
  let!(:agent) { create(:user, firm:) }

  before do
    @original_fixed_code = Rails.configuration.x.otp_fixed_code
    Rails.configuration.x.otp_fixed_code = nil
  end

  after { Rails.configuration.x.otp_fixed_code = @original_fixed_code }

  def request_code(mobile)
    post "/api/v1/auth/otp", params: { mobile: mobile.delete_prefix("+91") }, as: :json
    response.parsed_body
  end

  def sign_in(person)
    body = request_code(person.mobile)
    post "/api/v1/auth/verify",
      params: { request_id: body["request_id"], code: Auth::FieldDemo::CODE }, as: :json
    { "Authorization" => "Bearer #{response.parsed_body['access_token']}" }
  end

  it "issues 888888 for every user and sends nothing" do
    allow(Rails.logger).to receive(:info).and_call_original

    [ owner, agent ].each do |person|
      body = request_code(person.mobile)

      expect(response).to have_http_status(:ok)
      record = OneTimeCode.find(body["request_id"])
      expect(BCrypt::Password.new(record.code_digest)).to eq("888888")
    end

    expect(deliverer.deliveries).to be_empty
    expect(Rails.logger).to have_received(:info).with("[auth] field demo code issued").twice
    expect(Rails.logger).not_to have_received(:info).with(a_string_including("888888"))
  end

  it "signs the user in with that code and does not lock them out" do
    body = request_code(agent.mobile)

    3.times do
      post "/api/v1/auth/verify",
        params: { request_id: body["request_id"], code: "000000" }, as: :json
    end
    expect(agent.reload).not_to be_locked_out

    post "/api/v1/auth/verify",
      params: { request_id: body["request_id"], code: "888888" }, as: :json

    expect(response).to have_http_status(:ok)
    audit = AuditEvent.find_by(action: "user.signed_in", subject: agent)
    expect(audit.metadata).to include("field_demo" => true)
  end

  it "issues 888888 for email, mobile and WhatsApp verification and sends nothing" do
    headers = sign_in(owner)

    %i[email mobile whatsapp].each do |kind|
      channel = create(:contact_channel, kind, firm:)
      post "/api/v1/firm/contact_channels/#{channel.id}/request_code", headers: headers

      expect(response).to have_http_status(:ok)
      record = OneTimeCode.order(:created_at).last
      expect(record.purpose).to eq("verify_#{kind}")
      expect(BCrypt::Password.new(record.code_digest)).to eq("888888")
    end

    expect(deliverer.deliveries).to be_empty
  end

  it "still sends a real code for an ordinary firm" do
    ordinary = create(:firm, status: :active)
    create(:subscription, firm: ordinary, plan:)
    person = create(:user, :super_admin, firm: ordinary)
    allow(SecureRandom).to receive(:random_number).and_call_original
    allow(SecureRandom).to receive(:random_number).with(1_000_000).and_return(424242)

    request_code(person.mobile)

    expect(deliverer.last.code).to eq("424242")
    expect(deliverer.last.destination).to eq(person.mobile)
  end

  it "stays in the marketplace" do
    expect(Firm.marketplace_eligible).to include(firm)
  end
end
