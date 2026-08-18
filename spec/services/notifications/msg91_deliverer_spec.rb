# frozen_string_literal: true

require "rails_helper"

RSpec.describe Notifications::Msg91Deliverer do
  subject(:deliverer) { described_class.new }

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
      }.to raise_error(Notifications::Deliverer::DeliveryError, /sms_template_id/)
    end

    it "names every missing WhatsApp value at once" do
      with_credentials({ auth_key: "key" })

      expect {
        deliverer.deliver_code(transport: :whatsapp, destination: "+919820144210", code: "123456", purpose: "login")
      }.to raise_error(
        Notifications::Deliverer::DeliveryError,
        /whatsapp_number, whatsapp_template_name/
      )
    end

    it "lets SMS work while WhatsApp is still unconfigured" do
      # The transports are checked independently on purpose — SMS shouldn't wait
      # on WhatsApp Business onboarding.
      with_credentials({ auth_key: "key", sms_template_id: "tmpl-1" })
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
    before { with_credentials({ auth_key: "key", sms_template_id: "tmpl-1" }) }

    it "sends the number without a plus sign, as MSG91 expects" do
      request = stub_successful_post

      deliverer.deliver_code(transport: :sms, destination: "+919820144210", code: "123456", purpose: "login")

      expect(JSON.parse(request.body).dig("recipients", 0, "mobiles")).to eq("919820144210")
    end

    it "passes the code as the template variable rather than composing a message" do
      request = stub_successful_post

      deliverer.deliver_code(transport: :sms, destination: "+919820144210", code: "123456", purpose: "login")

      body = JSON.parse(request.body)
      expect(body["template_id"]).to eq("tmpl-1")
      expect(body.dig("recipients", 0, "otp")).to eq("123456")
    end

    it "authenticates with the auth key header" do
      request = stub_successful_post

      deliverer.deliver_code(transport: :sms, destination: "+919820144210", code: "123456", purpose: "login")

      expect(request["authkey"]).to eq("key")
    end

    it "routes email through Action Mailer, not MSG91" do
      expect {
        deliverer.deliver_code(transport: :email, destination: "ops@example.com", code: "123456", purpose: "verify_email")
      }.to have_enqueued_job(ActionMailer::MailDeliveryJob)
    end

    it "rejects an unknown transport" do
      expect {
        deliverer.deliver_code(transport: :carrier_pigeon, destination: "x", code: "1", purpose: "login")
      }.to raise_error(Notifications::Deliverer::DeliveryError, /Unknown transport/)
    end
  end

  describe "when MSG91 misbehaves" do
    before { with_credentials({ auth_key: "key", sms_template_id: "tmpl-1" }) }

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
    it "reports each transport independently" do
      with_credentials({ auth_key: "key", sms_template_id: "tmpl-1" })

      status = described_class.configuration_status

      expect(status[:sms][:ready]).to be(true)
      expect(status[:whatsapp][:ready]).to be(false)
      expect(status[:whatsapp][:missing]).to contain_exactly(:whatsapp_number, :whatsapp_template_name)
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
