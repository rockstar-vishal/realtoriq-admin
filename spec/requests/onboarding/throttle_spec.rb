# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Registration code caps" do
  it "stops mobile and WhatsApp at the hourly cap, emails ops once, and still sends email" do
    memory = ActiveSupport::Cache::MemoryStore.new
    allow(Rails).to receive(:cache).and_return(memory)
    allow(Onboarding::Throttle).to receive(:hourly_cap).and_return(1)

    post registration_send_code_path(kind: "mobile"), params: { mobile: "9876543210" }
    expect(response).to have_http_status(:ok)
    expect(response.body).to include("Code sent.")

    travel 2.minutes
    post registration_send_code_path(kind: "mobile"), params: { mobile: "9876543210" }
    expect(response).to have_http_status(:unprocessable_content)
    expect(response.body).to include(Onboarding::BUSY)

    travel 2.minutes
    post registration_send_code_path(kind: "whatsapp"), params: { whatsapp: "9876543212" }
    expect(response).to have_http_status(:unprocessable_content)
    expect(response.body).to include(Onboarding::BUSY)
    expect(ActiveJob::Base.queue_adapter.enqueued_jobs.count { |job|
      job[:job] == ActionMailer::MailDeliveryJob && job[:args][1] == "otp_cap_reached"
    }).to eq(1)

    post registration_send_code_path(kind: "email"), params: { email: "asha@example.com" }
    expect(response).to have_http_status(:ok)
    expect(response.body).to include("Code sent.")
    expect(deliverer.last.transport).to eq(:email)
  end

  it "caps repeated sends to one number, and distinct numbers, for one sitting" do
    memory = ActiveSupport::Cache::MemoryStore.new
    allow(Rails).to receive(:cache).and_return(memory)

    5.times do |index|
      travel (index * 61).seconds
      post registration_send_code_path(kind: "mobile"), params: { mobile: "9876543210" }
      expect(response).to have_http_status(:ok)
    end

    travel 6.minutes
    post registration_send_code_path(kind: "mobile"), params: { mobile: "9876543210" }
    expect(response).to have_http_status(:unprocessable_content)
    expect(response.body).to include(Onboarding::TOO_MANY)

    3.times do |index|
      travel (10 + index).minutes
      post registration_send_code_path(kind: "whatsapp"), params: { whatsapp: "912345678#{index}" }
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Code sent.")
    end

    travel 20.minutes
    post registration_send_code_path(kind: "whatsapp"), params: { whatsapp: "9123456789" }
    expect(response).to have_http_status(:unprocessable_content)
    expect(response.body).to include(Onboarding::TOO_MANY)
  end
end
