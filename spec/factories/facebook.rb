# frozen_string_literal: true

FactoryBot.define do
  factory :facebook_connection do
    firm
    connected_by_user { association :user, :super_admin, firm: }
    sequence(:fb_user_id) { |n| "fb-user-#{n}" }
    fb_user_name { "Harbour Realty" }
    token_kind { "system_access" }
    access_token { "user-token" }
    token_obtained_at { Time.current }
    status { "active" }
  end

  factory :facebook_page do
    firm
    facebook_connection { association :facebook_connection, firm: }
    sequence(:page_id) { |n| "page-#{n}" }
    page_name { "Harbour Page" }
    page_access_token { "page-token" }
    subscribed { false }
    status { "unsubscribed" }
  end

  factory :facebook_lead_form do
    firm
    facebook_page { association :facebook_page, firm: }
    sequence(:form_id) { |n| "form-#{n}" }
    form_name { "Harbour enquiry" }
    active { true }
  end

  factory :facebook_lead_import do
    firm
    facebook_page { association :facebook_page, firm: }
    sequence(:leadgen_id) { |n| "leadgen-#{n}" }
    status { "pending" }
    raw_payload { {} }
  end

  factory :facebook_oauth_attempt do
    firm
    user { association :user, :super_admin, firm: }
    nonce_digest { Digest::SHA256.hexdigest("nonce-#{SecureRandom.hex(8)}") }
    status { "started" }
    expires_at { 15.minutes.from_now }
  end

  factory :facebook_import_alert_state do
    firm
  end
end
