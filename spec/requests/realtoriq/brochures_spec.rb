# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Public project brochure" do
  let(:project) { create(:project, name: "Shikhar Greens") }

  def attach_pdf(record, bytes = "%PDF-1.4 brochure")
    record.brochure.attach(
      io: StringIO.new(bytes), filename: "SHIKAR GREENS BROCHURE.pdf", content_type: "application/pdf"
    )
  end

  def catalog_with(url)
    Current.set(firm: nil, firm_scope_bypassed: true) do
      create(:project, :catalog, firm: nil, name: "Shikhar Greens", external_ref: "PR23554A",
        brochure_source_url: url)
    end
  end

  def allow_launch_host
    allow(Realtoriq::Credentials).to receive(:turbo_public_origin).and_return("https://r.example")
    allow(Realtoriq::Credentials).to receive(:turbo_api_origin).and_return("https://r.example")
  end

  # The share payload is built outside a request, so its host is APP_HOST
  # (localhost:3000 here), not the host of whatever request the spec just made.
  def public_brochure_url(record)
    Rails.application.routes.url_helpers.realtoriq_brochure_url(record.code, format: :pdf)
  end

  it "streams an uploaded brochure without the storage path" do
    attach_pdf(project)

    get realtoriq_brochure_path(project.code, format: :pdf)

    expect(response).to have_http_status(:ok)
    expect(response).not_to have_http_status(:redirect)
    expect(response.media_type).to eq("application/pdf")
    expect(response.body).to eq("%PDF-1.4 brochure")
    expect(response.body).not_to include("active_storage")
    expect(response.headers["Cache-Control"]).to include("no-store")
    expect(response.headers["X-Content-Type-Options"]).to eq("nosniff")
    expect(response.headers["Content-Disposition"]).to include("inline")
    expect(response.headers["Content-Disposition"]).to include("Shikhar-Greens.pdf")
    expect(response.headers["Location"]).to be_nil
  end

  it "publishes that path on the project the broker shares" do
    attach_pdf(project)
    payload = Api::V1::ProjectSerializer.detail(project)
    url = public_brochure_url(project)

    expect(payload[:brochure_url]).to eq(url)
    expect(payload[:shareable][:brochure_url]).to eq(url)
    expect(url).to include("/realtoriq/brochures/#{project.code}.pdf")
    expect(url).not_to include("active_storage")
  end

  it "points a marketplace brochure at LaunchIQ and does not fetch the file" do
    catalog = catalog_with("https://r.example/rails/active_storage/blobs/redirect/abc/file.pdf")
    allow_launch_host
    expect(Realtoriq::RemoteFile).not_to receive(:fetch)

    url = Api::V1::ProjectSerializer.shareable(catalog)[:brochure_url]

    expect(url).to eq("https://r.example/realtoriq/brochures/PR23554A")
    expect(url).not_to include("active_storage")
    expect(Api::V1::ProjectSerializer.detail(catalog)[:brochure_url]).to eq(url)

    get realtoriq_brochure_path(catalog.code, format: :pdf)
    expect(response).to have_http_status(:not_found)
  end

  it "keeps the stored brochure link when the LaunchIQ origin is unset" do
    catalog = catalog_with("https://r.example/rails/active_storage/blobs/redirect/abc/file.pdf")
    allow(Realtoriq::Credentials).to receive(:turbo_public_origin).and_return("")

    expect(Api::V1::ProjectSerializer.shareable(catalog)[:brochure_url]).to eq(catalog.brochure_source_url)
  end

  it "keeps a firm's own upload on this app when the project also has a LaunchIQ code" do
    own = create(:project, name: "Own Greens", external_ref: "PR23554A")
    attach_pdf(own)
    allow_launch_host

    url = Api::V1::ProjectSerializer.shareable(own)[:brochure_url]

    expect(url).to eq(public_brochure_url(own))
    expect(url).not_to include("r.example")
  end

  it "is 404 when the project has no brochure" do
    get realtoriq_brochure_path(project.code, format: :pdf)

    expect(response).to have_http_status(:not_found)
  end

  it "is 404 for an unknown code" do
    get "/realtoriq/brochures/P-ZZZZZZ.pdf"

    expect(response).to have_http_status(:not_found)
  end

  it "does not serve a file that is not a pdf" do
    project.brochure.attach(io: StringIO.new("<html>no</html>"), filename: "x.html", content_type: "text/html")

    get realtoriq_brochure_path(project.code, format: :pdf)

    expect(response).to have_http_status(:not_found)
    expect(response.body).not_to include("<html>")
  end
end
