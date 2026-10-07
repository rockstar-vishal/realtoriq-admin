# frozen_string_literal: true

require "rails_helper"

# CORS and the S3 bucket are environment variables, filled from
# config/application.yml by Figaro. They must not grow a credentials fallback.
RSpec.describe "Figaro" do
  def sample_path
    Rails.root.join("config/application.yml.sample")
  end

  def restore_env(saved)
    saved.each do |key, value|
      value.nil? ? ENV.delete(key) : ENV[key] = value
    end
  end

  def without_figaro_env
    keys = %w[CORS_ORIGINS AWS_BUCKET _FIGARO_CORS_ORIGINS _FIGARO_AWS_BUCKET]
    saved = keys.index_with { |key| ENV[key] }
    keys.each { |key| ENV.delete(key) }
    yield
  ensure
    restore_env(saved)
  end

  def load_sample(environment)
    Figaro::Application.new(path: sample_path, environment: environment).load
  end

  it "ships a sample and keeps the real file out of git" do
    expect(Rails.root.join("Gemfile").read).to match(/gem "figaro", "~> 1\.3"/)
    expect(Rails.root.join(".gitignore").read).to include("config/application.yml")
    expect(sample_path).to exist
  end

  it "loads development origins and does not invent a bucket" do
    without_figaro_env do
      load_sample("development")

      expect(ENV["CORS_ORIGINS"]).to eq("http://localhost:3000,http://127.0.0.1:3000")
      expect(ENV["AWS_BUCKET"]).to be_nil
    end
  end

  it "loads the production origin and bucket" do
    without_figaro_env do
      load_sample("production")

      expect(ENV["CORS_ORIGINS"]).to eq("https://your-frontend-origin")
      expect(ENV["AWS_BUCKET"]).to eq("your-bucket-name")
    end
  end

  it "leaves staging on its wildcard by not setting CORS_ORIGINS" do
    without_figaro_env do
      load_sample("staging")

      expect(ENV["CORS_ORIGINS"]).to be_nil
      expect(ENV["AWS_BUCKET"]).to be_nil
    end
  end

  it "does not override a variable the process already has" do
    without_figaro_env do
      ENV["AWS_BUCKET"] = "already-set"

      expect { load_sample("production") }.to output(/Skipping key "AWS_BUCKET"/).to_stderr
      expect(ENV["AWS_BUCKET"]).to eq("already-set")
      expect(ENV["CORS_ORIGINS"]).to eq("https://your-frontend-origin")
    end
  end

  it "reads the bucket from ENV and not from credentials" do
    source = Rails.root.join("config/storage.yml").read

    expect(source).to include('bucket: <%= ENV["AWS_BUCKET"] %>')
    expect(source).not_to include("credentials.dig(:aws, :bucket")
  end
end
