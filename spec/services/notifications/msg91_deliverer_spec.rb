# frozen_string_literal: true

require "rails_helper"

RSpec.describe Notifications::Msg91Deliverer do
  subject(:deliverer) { described_class.new }

  let(:sms_credentials) do
    { auth_key: "key", sms_template_id: "6964d8c936b016228a36e8e2", sms_sender_id: "KGENIN" }
  end

  def with_credentials(settings)
    allow(Rails.application.credentials).to receive(:msg91).and_return(settings)
  end

  describe "partial configuration" do
    it "raises a DeliveryError naming what's missing, not a KeyError" do
      # With only an auth key present, a bare fetch would raise KeyError and
      # surface as a 500. The API contract is `delivery_failed`.
      with_credentials({ auth_key: "key" })

      expect {
        deliverer.deliver_code(transport: :sms, destination: "+919820144210", code: "123456", purpose: "login")
      }.to raise_error(Notifications::Deliverer::DeliveryError, /sms_template_id, sms_sender_id/)
    end

    it "sends SMS without any WhatsApp credentials" do
      # Sign-in is SMS. It must not wait on the Twilio account.
      with_credentials(sms_credentials)
      stub_successful_post

      expect {
        deliverer.deliver_code(transport: :sms, destination: "+919820144210", code: "123456", purpose: "login")
      }.not_to raise_error
    end

    it "raises when nothing is configured at all" do
      with_credentials(nil)

      expect {
        deliverer.deliver_code(transport: :sms, destination: "+919820144210", code: "123456", purpose: "login")
      }.to raise_error(Notifications::Deliverer::DeliveryError, /not configured/)
    end
  end

  describe "#deliver_code" do
    before { with_credentials(sms_credentials) }

    it "sends the number without a plus sign, as MSG91 expects" do
      request = stub_successful_post

      deliverer.deliver_code(transport: :sms, destination: "+919820144210", code: "123456", purpose: "login")

      expect(JSON.parse(request.body).dig("recipients", 0, "mobiles")).to eq("919820144210")
    end

    it "passes the code as var1, with the approved sender, and does not compose a message" do
      request = stub_successful_post

      deliverer.deliver_code(transport: :sms, destination: "+919820144210", code: "123456", purpose: "login")

      body = JSON.parse(request.body)
      expect(body["template_id"]).to eq("6964d8c936b016228a36e8e2")
      expect(body["sender"]).to eq("KGENIN")
      expect(body.dig("recipients", 0, "var1")).to eq("123456")
      expect(body["short_url"]).to eq("0")
      expect(body.keys).to contain_exactly("template_id", "sender", "short_url", "recipients")
    end

    it "authenticates with the auth key header" do
      request = stub_successful_post

      deliverer.deliver_code(transport: :sms, destination: "+919820144210", code: "123456", purpose: "login")

      expect(request["authkey"]).to eq("key")
    end

    it "leaves WhatsApp and email to the other deliverers" do
      expect {
        deliverer.deliver_code(transport: :whatsapp, destination: "+919820144210", code: "123456", purpose: "verify_whatsapp")
      }.to raise_error(Notifications::Deliverer::DeliveryError, /Unknown transport/)

      expect {
        deliverer.deliver_code(transport: :email, destination: "ops@example.com", code: "123456", purpose: "verify_email")
      }.to raise_error(Notifications::Deliverer::DeliveryError, /Unknown transport/)
    end
  end

  describe "when MSG91 misbehaves" do
    before { with_credentials(sms_credentials) }

    it "turns a failure response into a DeliveryError without leaking the code" do
      response = instance_double(Net::HTTPBadRequest, code: "400")
      allow(response).to receive(:is_a?).with(Net::HTTPSuccess).and_return(false)
      allow(Net::HTTP).to receive(:start).and_return(response)

      expect {
        deliverer.deliver_code(transport: :sms, destination: "+919820144210", code: "123456", purpose: "login")
      }.to raise_error(Notifications::Deliverer::DeliveryError) { |error|
        expect(error.message).to include("400")
        expect(error.message).not_to include("123456")
      }
    end

    it "turns a timeout into a DeliveryError rather than hanging the request" do
      allow(Net::HTTP).to receive(:start).and_raise(Net::OpenTimeout)

      expect {
        deliverer.deliver_code(transport: :sms, destination: "+919820144210", code: "123456", purpose: "login")
      }.to raise_error(Notifications::Deliverer::DeliveryError, /unreachable/)
    end
  end

  describe ".configuration_status" do
    it "reports SMS on its own" do
      with_credentials(sms_credentials)

      status = described_class.configuration_status

      expect(status[:sms][:ready]).to be(true)
      expect(status.keys).to contain_exactly(:sms)
    end

    it "names every missing SMS value" do
      with_credentials({ auth_key: "key" })

      status = described_class.configuration_status

      expect(status[:sms][:ready]).to be(false)
      expect(status[:sms][:missing]).to contain_exactly(:sms_template_id, :sms_sender_id)
    end
  end

  # Captures the request MSG91 would have received.
  def stub_successful_post
    captured = nil
    response = instance_double(Net::HTTPOK)
    allow(response).to receive(:is_a?).with(Net::HTTPSuccess).and_return(true)

    allow(Net::HTTP).to receive(:start) do |*_args, &block|
      http = instance_double(Net::HTTP)
      allow(http).to receive(:request) { |req| captured = req; response }
      block.call(http)
    end

    # The spec reads this after the call, so hand back a proxy that resolves then.
    Class.new do
      define_method(:body) { captured.body }
      define_method(:[]) { |key| captured[key] }
    end.new
  end
end
