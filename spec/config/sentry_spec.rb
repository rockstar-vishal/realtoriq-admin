# frozen_string_literal: true

require "rails_helper"

# These are the settings that keep OTP codes, JWTs and presigned S3 URLs out of
# Sentry. A comment in the initializer is not enough: turning send_default_pii
# on, or leaving the storage URL in a breadcrumb, fails silently.
RSpec.describe "Sentry" do
  it "reports production only and does not collect request bodies" do
    configuration = Sentry.configuration

    expect(configuration.enabled_environments).to eq(%w[production])
    expect(configuration.send_default_pii).to be(false)
    expect(configuration.breadcrumbs_logger).to eq(%i[active_support_logger http_logger])
  end

  it "strips SQL text and presigned storage URLs from breadcrumbs" do
    scrub = Sentry.configuration.before_breadcrumb

    sql = Sentry::Breadcrumb.new(
      category: "sql.active_record",
      data: { sql: "SELECT 1", name: "User Load" }
    )
    stored = Sentry::Breadcrumb.new(
      category: "service_url.active_storage",
      data: { url: "https://s3.example/signed", key: "abc" }
    )
    kept = Sentry::Breadcrumb.new(
      category: "process_action.action_controller",
      data: { status: 500 }
    )

    expect(scrub.call(sql, {}).data).to eq({ name: "User Load" })
    expect(scrub.call(stored, {}).data).to eq({ key: "abc" })
    expect(scrub.call(kept, {}).data).to eq({ status: 500 })
  end
end
