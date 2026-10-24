# frozen_string_literal: true

require "rails_helper"

RSpec.describe "project list queries" do
  let(:plan) { create(:plan) }
  let(:firm) { create(:firm, status: :active) }
  let!(:subscription) { create(:subscription, firm:, plan:) }
  let!(:user) { create(:user, :super_admin, firm:) }
  let(:city) { create(:city) }
  let(:builder) { create(:builder, firm: nil) }
  let(:typology) { create(:typology, name: "2 BHK") }

  def auth
    post "/api/v1/auth/otp", params: { mobile: user.mobile }, as: :json
    request_id = response.parsed_body["request_id"]
    post "/api/v1/auth/verify", params: { request_id:, code: deliverer.last.code }, as: :json
    { "Authorization" => "Bearer #{response.parsed_body['access_token']}" }
  end

  def catalog_with_photos(name, count: 2)
    Current.set(firm: nil, firm_scope_bypassed: true) do
      project = create(:project, :catalog, firm: nil, name:, builder:, city:,
        external_ref: "PR#{SecureRandom.hex(3).upcase}")
      create(:project_typology, project:, typology:, starting_price: 15_000_000)
      count.times do |n|
        project.photos.attach(io: StringIO.new("photo-#{name}-#{n}"), filename: "p#{n}.jpg", content_type: "image/jpeg")
      end
      project
    end
  end

  def select_count
    queries = []
    callback = lambda do |_name, _start, _finish, _id, payload|
      sql = payload[:sql].to_s
      next if payload[:name] == "SCHEMA"
      queries << sql if sql.start_with?("SELECT")
    end
    ActiveSupport::Notifications.subscribed(callback, "sql.active_record") { yield }
    queries.size
  end

  it "does not add a query per project or per photo" do
    2.times { |n| catalog_with_photos("Small #{n}") }
    headers = auth
    small = select_count { get "/api/v1/projects", params: { source: "catalog", per_page: 50 }, headers: }

    18.times { |n| catalog_with_photos("Large #{n}") }
    large = select_count { get "/api/v1/projects", params: { source: "catalog", per_page: 50 }, headers: }

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body["projects"].size).to eq(20)
    expect(response.parsed_body.dig("projects", 0, "cover_photo_url")).to be_present
    expect(response.parsed_body.dig("projects", 0, "cover_thumb_url")).to include("/rails/active_storage/representations/")
    expect(large).to eq(small)
  end

  # cover_thumb_url touches every photo's variant_records. with_attached_photos
  # preloads those, so more photos must not add selects. Drop the preload and
  # this count grows.
  it "does not add a query per photo" do
    projects = 2.times.map { |n| catalog_with_photos("Photo #{n}", count: 1) }
    headers = auth
    few = select_count { get "/api/v1/projects", params: { source: "catalog", per_page: 50 }, headers: }

    projects.each do |project|
      7.times do |n|
        project.photos.attach(
          io: StringIO.new("extra-#{project.id}-#{n}"),
          filename: "e#{n}.jpg",
          content_type: "image/jpeg"
        )
      end
    end

    many = select_count { get "/api/v1/projects", params: { source: "catalog", per_page: 50 }, headers: }

    expect(many).to eq(few)
    thumbs = response.parsed_body["projects"].map { |row| row["cover_thumb_url"] }
    expect(thumbs).to all(include("/rails/active_storage/representations/"))
  end
end
