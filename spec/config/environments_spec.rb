# frozen_string_literal: true

require "rails_helper"

# Staging exists so the app can be exercised without reaching a real broker or a
# real rupee. These are the properties that make that true, asserted rather than
# left to a comment — the failure mode is silent, and expensive.
RSpec.describe "Environment guarantees" do
  # Evaluated the way config/application.rb does, without booting a second app.
  def config_for(env)
    {
      otp_fixed_code: ENV["OTP_FIXED_CODE"].presence ||
        ("888888" if env.in?(%w[development staging])),
      otp_delivery: ENV.fetch("OTP_DELIVERY") { env == "production" ? "msg91" : "log" },
      otp_rate_limit: env == "production" ? 12 : 100
    }
  end

  around do |example|
    original = ENV.to_hash
    ENV.delete("OTP_FIXED_CODE")
    ENV.delete("OTP_DELIVERY")
    example.run
    ENV.replace(original)
  end

  describe "staging" do
    it "pins sign-in codes to 888888 without needing a variable set" do
      expect(config_for("staging")[:otp_fixed_code]).to eq("888888")
    end

    it "never talks to MSG91 — codes go to the log" do
      expect(config_for("staging")[:otp_delivery]).to eq("log")
    end

    it "has a loose rate limit, for QA passes" do
      expect(config_for("staging")[:otp_rate_limit]).to eq(100)
    end

    it "is its own environment, not production with a flag" do
      # The production guard must stay absolute; an escape hatch production
      # could take would not be a guard.
      expect(Rails.root.join("config/environments/staging.rb")).to exist
    end

    it "is configured for every Solid adapter, or it cannot boot" do
      %w[cable cache queue].each do |adapter|
        config = YAML.load_file(Rails.root.join("config/#{adapter}.yml"), aliases: true)
        expect(config).to have_key("staging"), "config/#{adapter}.yml is missing a staging entry"
      end
    end

    it "has its own databases, so it can never point at production's" do
      # Read through Rails rather than YAML.load_file: database.yml carries ERB
      # conditionals, so raw YAML parsing would choke on them.
      primary = ActiveRecord::Base.configurations
        .configs_for(env_name: "staging", name: "primary").configuration_hash

      expect(primary[:database]).to include("staging")
      expect(primary[:database]).not_to include("production")
    end

    it "connects over the Unix socket by default, so no password is needed" do
      # Naming a host — even "localhost" — forces TCP, where Ubuntu's pg_hba.conf
      # demands a password and you get "fe_sendauth: no password supplied".
      # Emitting no host at all is what makes peer authentication work.
      primary = ActiveRecord::Base.configurations
        .configs_for(env_name: "staging", name: "primary").configuration_hash

      expect(primary[:host]).to be_nil
      expect(primary[:username]).to be_nil
    end
  end

  describe "production" do
    it "has no default fixed code" do
      expect(config_for("production")[:otp_fixed_code]).to be_nil
    end

    it "sends through MSG91" do
      expect(config_for("production")[:otp_delivery]).to eq("msg91")
    end

    it "keeps the tight rate limit" do
      expect(config_for("production")[:otp_rate_limit]).to eq(12)
    end

    it "refuses to boot if a fixed code is supplied" do
      source = Rails.root.join("config/initializers/otp_fixed_code.rb").read

      expect(source).to include("Rails.env.production?")
      expect(source).to match(/raise/)
    end
  end

  describe "the LogDeliverer" do
    it "refuses to run in production even if configuration drifts" do
      allow(Rails).to receive(:env).and_return(ActiveSupport::StringInquirer.new("production"))

      expect {
        Notifications::LogDeliverer.new.deliver_code(
          transport: :sms, destination: "+919820144210", code: "888888", purpose: "login"
        )
      }.to raise_error(Notifications::Deliverer::DeliveryError, /never run in production/)
    end
  end
end
