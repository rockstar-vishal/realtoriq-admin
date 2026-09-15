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

  # Mirrors config/initializers/cors.rb without booting a second app.
  def cors_origins_for(env, configured = nil)
    origins = configured.to_s.split(",").map(&:strip).compact_blank
    return origins if origins.any?

    env == "staging" ? [ "*" ] : %w[http://localhost:3000 http://127.0.0.1:3000]
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

    it "stores files on disk, and cannot be pointed at a bucket" do
      # One stray environment variable would otherwise put staging in the
      # production bucket, writing test uploads among real documents — and
      # purging a real blob whenever a tester deleted a photo.
      source = Rails.root.join("config/environments/staging.rb").read

      expect(source).to include("config.active_storage.service = :local")
      expect(source).not_to match(/active_storage\.service\s*=\s*ENV/)
    end

    it "answers any origin, so a preview build can talk to it unannounced" do
      expect(cors_origins_for("staging")).to eq([ "*" ])
    end

    it "still takes an explicit list when one is given" do
      expect(cors_origins_for("staging", "https://app.realtoriq.com"))
        .to eq([ "https://app.realtoriq.com" ])
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

    it "stores files on S3, because a container's disk does not survive a deploy" do
      source = Rails.root.join("config/environments/production.rb").read

      expect(source).to include('ENV.fetch("STORAGE_SERVICE", "amazon")')
    end

    it "refuses to boot on S3 without a bucket" do
      # Active Storage builds the service during boot, before initializers, so
      # this has to be checked in the environment file or the failure is an
      # ArgumentError out of the AWS SDK that names nothing useful.
      source = Rails.root.join("config/environments/production.rb").read

      expect(source).to include("AWS_BUCKET")
      expect(source).to match(/raise/)
    end

    it "has the S3 gem available to it" do
      expect(Rails.root.join("Gemfile").read).to match(/gem "aws-sdk-s3"/)
    end

    it "does not inherit staging's open CORS" do
      expect(cors_origins_for("production")).not_to include("*")
    end
  end

  describe "CORS" do
    it "never covers the admin panel, which runs on a cookie session" do
      # A wildcard origin is only tolerable because /api/* carries no ambient
      # authority. The admin panel does, so it must stay outside the resource.
      source = Rails.root.join("config/initializers/cors.rb").read

      expect(source).to include('resource "/api/*"')
      expect(source).not_to include('resource "/admin')
      expect(source).not_to match(/resource ["']\*["']/)
    end

    it "covers the direct-upload path, or step 2 of every upload dies in a browser" do
      # POST /api/v1/uploads hands back a direct_upload.url under
      # /rails/active_storage/disk/..., not under /api — so a rule scoped to
      # /api/* alone lets curl through (no Origin, no preflight) while every
      # browser and webview client fails the PUT with nothing in the logs.
      source = Rails.root.join("config/initializers/cors.rb").read

      expect(source).to include('resource "/rails/active_storage/*"')
      expect(source).to include("http://localhost:3000")
    end

    it "never sends credentials, which is what keeps the wildcard safe" do
      # rack-cors 3 defaults credentials to false and refuses to combine `true`
      # with `*` at all. Asserted because re-adding it would be silent here and
      # loud in production.
      source = Rails.root.join("config/initializers/cors.rb").read

      expect(source).not_to match(/credentials:\s*true/)
    end
  end

  describe "parameter logging" do
    it "redacts the sign-in code, which is named code not otp" do
      filter = ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters)

      expect(filter.filter("code" => "888888")["code"]).to eq("[FILTERED]")
    end
  end

  describe "TRUSTED_PROXIES" do
    it "is wired so a public BFF address can be trusted for X-Forwarded-For" do
      source = Rails.root.join("config/application.rb").read

      expect(source).to include("TRUSTED_PROXIES")
      expect(source).to include("trusted_proxies")
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
