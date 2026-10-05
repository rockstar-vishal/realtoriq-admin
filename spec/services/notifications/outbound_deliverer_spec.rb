# frozen_string_literal: true

require "rails_helper"

RSpec.describe Notifications::OutboundDeliverer do
  subject(:deliverer) { described_class.new }

  it "sends SMS through MSG91" do
    sms = instance_double(Notifications::Msg91Deliverer)
    allow(Notifications::Msg91Deliverer).to receive(:new).and_return(sms)
    expect(sms).to receive(:deliver_code).with(
      transport: :sms, destination: "+919820144210", code: "123456", purpose: "login"
    ).and_return(true)

    deliverer.deliver_code(transport: :sms, destination: "+919820144210", code: "123456", purpose: "login")
  end

  it "sends WhatsApp through Twilio" do
    whatsapp = instance_double(Notifications::TwilioDeliverer)
    allow(Notifications::TwilioDeliverer).to receive(:new).and_return(whatsapp)
    expect(whatsapp).to receive(:deliver_code).with(
      transport: :whatsapp, destination: "+919820144210", code: "123456", purpose: "verify_whatsapp"
    ).and_return(true)

    deliverer.deliver_code(transport: :whatsapp, destination: "+919820144210", code: "123456", purpose: "verify_whatsapp")
  end

  it "routes email through Action Mailer" do
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

RSpec.describe Notifications::Deliverer do
  it "uses real providers when OTP delivery is msg91" do
    allow(Rails.configuration.x).to receive(:otp_delivery).and_return("msg91")

    expect(described_class.build).to be_a(Notifications::OutboundDeliverer)
  end

  it "logs codes for every other setting" do
    allow(Rails.configuration.x).to receive(:otp_delivery).and_return("log")

    expect(described_class.build).to be_a(Notifications::LogDeliverer)
  end
end
