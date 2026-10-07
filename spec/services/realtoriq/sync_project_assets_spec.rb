# frozen_string_literal: true

require "rails_helper"
require "openssl"

RSpec.describe Realtoriq::SyncProjectAssets do
  include ActiveJob::TestHelper
  let(:city) { create(:city) }
  let(:builder) { create(:builder, name: "Lodha") }
  let(:project) do
    Current.set(firm_scope_bypassed: true) do
      create(:project, :catalog, firm: nil, builder:, city:, external_ref: "PR4F2A9C", name: "Harbour One")
    end
  end

  def checksum(bytes)
    OpenSSL::Digest::MD5.base64digest(bytes)
  end

  it "keeps an attachment whose checksum is unchanged and drops one that left the payload" do
    kept = "kept-bytes"
    gone = "gone-bytes"
    Current.set(firm_scope_bypassed: true) do
      project.photos.attach(io: StringIO.new(kept), filename: "kept.jpg")
      project.photos.attach(io: StringIO.new(gone), filename: "gone.jpg")
      project.brochure.attach(io: StringIO.new("brochure"), filename: "brochure.pdf")
    end
    brochure_url = nil
    Current.set(firm_scope_bypassed: true) do
      brochure_url = Rails.application.routes.url_helpers.rails_blob_url(project.brochure, only_path: true)
    end

    expect(Realtoriq::RemoteFile).not_to receive(:fetch)
    described_class.call(
      project:,
      images: [ { "url" => "https://launch.example/kept.jpg", "checksum" => checksum(kept), "filename" => "kept.jpg" } ],
      brochure: { "url" => "https://launch.example/brochure.pdf", "checksum" => checksum("brochure"), "filename" => "brochure.pdf" }
    )

    Current.set(firm_scope_bypassed: true) do
      perform_enqueued_jobs
      project.reload
      expect(project.photos.blobs.map(&:checksum)).to eq([ checksum(kept) ])
      expect(Rails.application.routes.url_helpers.rails_blob_url(project.brochure.reload, only_path: true)).to eq(brochure_url)
    end
  end

  it "does not replace photos with an older push" do
    kept = "kept-bytes"
    Current.set(firm_scope_bypassed: true) do
      project.photos.attach(io: StringIO.new(kept), filename: "kept.jpg")
      project.update!(turbo_pushed_at: Time.current)
    end
    expect(Realtoriq::RemoteFile).not_to receive(:fetch)

    described_class.call(
      project:,
      images: [ { "url" => "https://launch.example/old.jpg", "checksum" => checksum("old"), "filename" => "old.jpg" } ],
      brochure: nil,
      pushed_at: 1.hour.ago
    )

    Current.set(firm_scope_bypassed: true) do
      expect(project.photos.blobs.map(&:checksum)).to eq([ checksum(kept) ])
    end
  end

  it "does not attach a download that finishes after a newer push" do
    Current.set(firm_scope_bypassed: true) do
      project.update!(turbo_pushed_at: 1.hour.ago)
    end
    bytes = "old-bytes"
    allow(Realtoriq::RemoteFile).to receive(:fetch) do
      Project.unscoped.find(project.id).update!(turbo_pushed_at: Time.current)
      bytes
    end

    described_class.call(
      project:,
      images: [ { "url" => "https://launch.example/old.jpg", "checksum" => checksum(bytes), "filename" => "old.jpg" } ],
      brochure: nil,
      pushed_at: 1.hour.ago
    )

    Current.set(firm_scope_bypassed: true) do
      project.reload
      expect(project.photos).not_to be_attached
    end
  end

  it "replaces a photo that is still on another service, even when the checksum matches" do
    bytes = "kept-bytes"
    Current.set(firm_scope_bypassed: true) do
      project.photos.attach(io: StringIO.new(bytes), filename: "kept.jpg")
      project.photos.blobs.first.update!(service_name: "local")
    end
    allow(Realtoriq::RemoteFile).to receive(:fetch).and_return(bytes)

    described_class.call(
      project:,
      images: [ { "url" => "https://launch.example/kept.jpg", "checksum" => checksum(bytes), "filename" => "kept.jpg" } ],
      brochure: nil
    )

    Current.set(firm_scope_bypassed: true) do
      perform_enqueued_jobs
      project.reload
      expect(project.photos.blobs.map(&:service_name)).to eq([ "test" ])
      expect(project.photos.blobs.map(&:checksum)).to eq([ checksum(bytes) ])
    end
  end

  it "downloads a file whose checksum is new" do
    bytes = "new-photo"
    allow(Realtoriq::RemoteFile).to receive(:fetch).and_return(bytes)

    described_class.call(
      project:,
      images: [ { "url" => "https://launch.example/new.jpg", "checksum" => checksum(bytes), "filename" => "new.jpg" } ],
      brochure: nil
    )
    Current.set(firm_scope_bypassed: true) do
      project.reload
      expect(project.photos.blobs.map(&:checksum)).to eq([ checksum(bytes) ])
    end
  end
end
