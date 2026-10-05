# frozen_string_literal: true

require "rails_helper"

RSpec.describe Notifications::TwilioDeliverer do
  subject(:deliverer) { described_class.new }

  let(:twilio_credentials) do
    {
      account_sid: "AC#{'a' * 32}",
      auth_token: "token",
      whatsapp_from: "+919702671580",
      content_sid: "HX4b1eeff5911ca5f35df23cc2cc5eae8c"
    }
  end

  def with_credentials(settings)
    allow(Rails.application.credentials).to receive(:twilio).and_return(settings)
  end

  describe "partial configuration" do
    it "names every missing value at once" do
      with_credentials({ whatsapp_from: "+919702671580", content_sid: "HX4b1eeff5911ca5f35df23cc2cc5eae8c" })

      expect {
        deliverer.deliver_code(transport: :whatsapp, destination: "+919820144210", code: "123456", purpose: "verify_whatsapp")
      }.to raise_error(
        Notifications::Deliverer::DeliveryError,
        /account_sid, auth_token/
      )
    end

    it "raises when nothing is configured at all" do
      with_credentials(nil)

      expect {
        deliverer.deliver_code(transport: :whatsapp, destination: "+919820144210", code: "123456", purpose: "verify_whatsapp")
      }.to raise_error(Notifications::Deliverer::DeliveryError, /not configured/)
    end
  end

  describe "#deliver_code" do
    before { with_credentials(twilio_credentials) }

    it "sends the approved content template with the code in variable 1" do
      request = stub_successful_post

      deliverer.deliver_code(transport: :whatsapp, destination: "+919820144210", code: "123456", purpose: "verify_whatsapp")

      form = URI.decode_www_form(request.body).to_h
      expect(form["ContentSid"]).to eq("HX4b1eeff5911ca5f35df23cc2cc5eae8c")
      expect(form["ContentVariables"]).to eq('{"1":"123456"}')
      expect(form["From"]).to eq("whatsapp:+919702671580")
      expect(form["To"]).to eq("whatsapp:+919820144210")
      expect(form).not_to have_key("Body")
    end

    it "authenticates with the account sid and auth token" do
      request = stub_successful_post

      deliverer.deliver_code(transport: :whatsapp, destination: "+919820144210", code: "123456", purpose: "verify_whatsapp")

      expect(request["authorization"]).to eq("Basic #{Base64.strict_encode64("#{twilio_credentials[:account_sid]}:token")}")
    end

    it "rejects an account sid that is not an Account SID" do
      with_credentials(twilio_credentials.merge(account_sid: "not-a-sid"))

      expect {
        deliverer.deliver_code(transport: :whatsapp, destination: "+919820144210", code: "123456", purpose: "verify_whatsapp")
      }.to raise_error(Notifications::Deliverer::DeliveryError, /account_sid/)
    end

    it "does not send SMS" do
      expect {
        deliverer.deliver_code(transport: :sms, destination: "+919820144210", code: "123456", purpose: "login")
      }.to raise_error(Notifications::Deliverer::DeliveryError, /Unknown transport/)
    end
  end

  describe "when Twilio misbehaves" do
    before { with_credentials(twilio_credentials) }

    it "turns a failure response into a DeliveryError without leaking the code" do
      response = instance_double(Net::HTTPBadRequest, code: "400")
      allow(response).to receive(:is_a?).with(Net::HTTPSuccess).and_return(false)
      allow(Net::HTTP).to receive(:start).and_return(response)

      expect {
        deliverer.deliver_code(transport: :whatsapp, destination: "+919820144210", code: "123456", purpose: "verify_whatsapp")
      }.to raise_error(Notifications::Deliverer::DeliveryError) { |error|
        expect(error.message).to include("400")
        expect(error.message).not_to include("123456")
      }
    end

    it "turns a timeout into a DeliveryError rather than hanging the request" do
      allow(Net::HTTP).to receive(:start).and_raise(Net::OpenTimeout)

      expect {
        deliverer.deliver_code(transport: :whatsapp, destination: "+919820144210", code: "123456", purpose: "verify_whatsapp")
      }.to raise_error(Notifications::Deliverer::DeliveryError, /unreachable/)
    end
  end

  describe ".configuration_status" do
    it "reports WhatsApp on its own" do
      with_credentials(twilio_credentials.except(:account_sid, :auth_token))

      status = described_class.configuration_status

      expect(status[:whatsapp][:ready]).to be(false)
      expect(status[:whatsapp][:missing]).to contain_exactly(:account_sid, :auth_token)
    end
  end

  def stub_successful_post
    captured = nil
    response = instance_double(Net::HTTPCreated)
    allow(response).to receive(:is_a?).with(Net::HTTPSuccess).and_return(true)

    allow(Net::HTTP).to receive(:start) do |*_args, &block|
      http = instance_double(Net::HTTP)
      allow(http).to receive(:request) { |req| captured = req; response }
      block.call(http)
    end

    Class.new do
      define_method(:body) { captured.body }
      define_method(:[]) { |key| captured[key] }
    end.new
  end
end
