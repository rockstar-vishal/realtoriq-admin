# frozen_string_literal: true

require "rails_helper"

RSpec.describe "photo variants" do
  let(:plan) { create(:plan) }
  let(:firm) { create(:firm, status: :active) }
  let!(:subscription) { create(:subscription, firm:, plan:) }
  let!(:user) { create(:user, :super_admin, firm:) }

  def auth
    post "/api/v1/auth/otp", params: { mobile: user.mobile }, as: :json
    request_id = response.parsed_body["request_id"]
    post "/api/v1/auth/verify", params: { request_id:, code: deliverer.last.code }, as: :json
    { "Authorization" => "Bearer #{response.parsed_body['access_token']}" }
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

  it "declares a preprocessed thumb and large variant on projects and properties" do
    { thumb: [ [ 480, 480 ], 75 ], large: [ [ 1600, 1600 ], 80 ] }.each do |name, (limit, quality)|
      [ Project, Property ].each do |model|
        variant = model.reflect_on_attachment(:photos).named_variants.fetch(name)
        expect(variant.preprocessed).to be(true)
        expect(variant.transformations).to include(resize_to_limit: limit, format: :webp)
        expect(variant.transformations[:saver]).to include(quality:, strip: true)
      end
    end
  end

  it "enqueues both transforms when a photo is attached" do
    project = create(:project, firm:)

    expect {
      project.photos.attach(io: StringIO.new("a"), filename: "a.jpg", content_type: "image/jpeg")
    }.to have_enqueued_job(ActiveStorage::TransformJob).twice
  end

  it "serves representation urls on the detail and originals on shareable" do
    project = create(:project, firm:)
    project.photos.attach(io: StringIO.new("a"), filename: "a.jpg", content_type: "image/jpeg")
    project.photos.attachments.first.blob.update!(metadata: { "width" => 1200, "height" => 800 })

    get "/api/v1/projects/#{project.id}", headers: auth

    photo = response.parsed_body.dig("project", "photos", 0)
    expect(photo["url"]).to include("/rails/active_storage/blobs/")
    expect(photo["thumb_url"]).to include("/rails/active_storage/representations/")
    expect(photo["large_url"]).to include("/rails/active_storage/representations/")
    expect(photo["width"]).to eq(1200)
    expect(photo["height"]).to eq(800)
    expect(response.parsed_body.dig("project", "cover_photo_url")).to eq(photo["url"])
    expect(response.parsed_body.dig("project", "cover_thumb_url")).to eq(photo["thumb_url"])

    share = response.parsed_body.dig("project", "shareable", "photo_urls", 0)
    expect(share).to eq(photo["url"])
    expect(share).not_to include("/representations/")
  end

  it "falls back to the original when the blob cannot be transformed" do
    project = create(:project, firm:)
    project.photos.attach(io: StringIO.new("a"), filename: "a.pdf", content_type: "application/pdf")

    get "/api/v1/projects/#{project.id}", headers: auth

    photo = response.parsed_body.dig("project", "photos", 0)
    expect(photo["thumb_url"]).to eq(photo["url"])
    expect(photo["large_url"]).to eq(photo["url"])
    expect(photo["url"]).to include("/rails/active_storage/blobs/")
    expect(photo["width"]).to be_nil
    expect(photo["height"]).to be_nil
  end

  it "serves the same shape for a property, and shareable stays on the original" do
    property = create(:property, firm:, created_by_user: user)
    property.photos.attach(io: StringIO.new("a"), filename: "a.jpg", content_type: "image/jpeg")

    get "/api/v1/properties/#{property.id}", headers: auth

    photo = response.parsed_body.dig("property", "photos", 0)
    expect(photo["thumb_url"]).to include("/rails/active_storage/representations/")
    expect(photo["large_url"]).to include("/rails/active_storage/representations/")
    expect(response.parsed_body.dig("property", "cover_thumb_url")).to eq(photo["thumb_url"])
    expect(response.parsed_body.dig("property", "shareable", "photo_urls", 0)).to eq(photo["url"])
  end

  it "does not add a query per property photo" do
    properties = 2.times.map do |n|
      property = create(:property, firm:, created_by_user: user, building_name: "Photo House #{n}")
      property.photos.attach(io: StringIO.new("p-#{n}"), filename: "p.jpg", content_type: "image/jpeg")
      property
    end
    headers = auth
    few = select_count { get "/api/v1/properties", params: { per_page: 50 }, headers: }

    properties.each do |property|
      7.times do |n|
        property.photos.attach(
          io: StringIO.new("extra-#{property.id}-#{n}"),
          filename: "e#{n}.jpg",
          content_type: "image/jpeg"
        )
      end
    end

    many = select_count { get "/api/v1/properties", params: { per_page: 50 }, headers: }

    expect(many).to eq(few)
    thumbs = response.parsed_body["properties"].map { |row| row["cover_thumb_url"] }
    expect(thumbs).to all(include("/rails/active_storage/representations/"))
  end
end
