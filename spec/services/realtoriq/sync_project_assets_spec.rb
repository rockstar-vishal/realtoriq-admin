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
      # Attaching a photo also enqueues thumb and large transforms. These bytes
      # are not images. Only the purge of the dropped photo has to run.
      perform_enqueued_jobs(only: ActiveStorage::PurgeJob)
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
      # The original is on a service that has no file. Performing its variant
      # job would try to open it. The example only checks the replacement.
      perform_enqueued_jobs(only: ActiveStorage::PurgeJob)
      project.reload
      expect(project.photos.blobs.map(&:service_name)).to eq([ "test" ])
      expect(project.photos.blobs.map(&:checksum)).to eq([ checksum(bytes) ])
    end
  end

  it "skips a photo whose type is not allowed and still stores the rest" do
    bytes = "new-photo"
    brochure = "brochure-bytes"
    allow(Realtoriq::RemoteFile).to receive(:fetch) do |url, **|
      raise Realtoriq::RemoteFile::TypeError, "file type is not allowed" if url.end_with?(".pdf") && url.exclude?("brochure")

      url.include?("brochure") ? brochure : bytes
    end

    described_class.call(
      project:,
      images: [
        { "url" => "https://launch.example/plans.pdf", "checksum" => checksum("pdf"), "filename" => "plans.pdf" },
        { "url" => "https://launch.example/new.jpg", "checksum" => checksum(bytes), "filename" => "new.jpg" }
      ],
      brochure: { "url" => "https://launch.example/brochure.pdf", "checksum" => checksum(brochure), "filename" => "brochure.pdf" }
    )

    Current.set(firm_scope_bypassed: true) do
      project.reload
      expect(project.photos.blobs.map(&:checksum)).to eq([ checksum(bytes) ])
      expect(project.brochure.blob.checksum).to eq(checksum(brochure))
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

  def creative_row(id, bytes, content_type: "image/jpeg", title: "Front", position: 1, numbers: [])
    {
      "id" => id,
      "title" => title,
      "position" => position,
      "url" => "https://launch.example/#{id}",
      "checksum" => checksum(bytes),
      "filename" => "#{id}.bin",
      "content_type" => content_type,
      "registration_numbers" => numbers
    }
  end

  def pdf_bytes(pages)
    Prawn::Document.new do |pdf|
      pages.times do |index|
        pdf.text "Page #{index}"
        pdf.start_new_page unless index == pages - 1
      end
    end.render
  end

  it "adds creatives, replaces a changed checksum, and deletes one that left the payload" do
    kept = "kept-creative"
    changed = "changed-creative"
    gone = "gone-creative"
    allow(Realtoriq::RemoteFile).to receive(:fetch) { |url, **| url.split("/").last == "crt_gone" ? gone : kept }

    Current.set(firm_scope_bypassed: true) do
      described_class.call(
        project:, images: [], brochure: nil,
        creatives: [ creative_row("crt_keep", kept, numbers: [ "p1" ]), creative_row("crt_gone", gone) ]
      )
      expect(project.project_creatives.order(:external_id).pluck(:external_id)).to eq(%w[crt_gone crt_keep])
      expect(project.project_creatives.find_by(external_id: "crt_keep").registration_numbers).to eq([ "P1" ])
    end

    allow(Realtoriq::RemoteFile).to receive(:fetch).and_return(changed)
    Current.set(firm_scope_bypassed: true) do
      described_class.call(
        project:, images: [], brochure: nil,
        creatives: [ creative_row("crt_keep", changed, title: "Renamed", position: 3) ]
      )
      project.reload
      expect(project.project_creatives.pluck(:external_id)).to eq([ "crt_keep" ])
      row = project.project_creatives.find_by!(external_id: "crt_keep")
      expect(row.title).to eq("Renamed")
      expect(row.position).to eq(3)
      expect(row.file.blob.checksum).to eq(checksum(changed))
    end
  end

  it "skips a pdf with more than five pages and still stores the other creative" do
    image = "ok-image"
    long = pdf_bytes(6)
    allow(Realtoriq::RemoteFile).to receive(:fetch) { |url, **| url.include?("crt_long") ? long : image }

    Current.set(firm_scope_bypassed: true) do
      described_class.call(
        project:, images: [], brochure: nil,
        creatives: [
          creative_row("crt_long", long, content_type: "application/pdf"),
          creative_row("crt_ok", image)
        ]
      )
      expect(project.project_creatives.pluck(:external_id)).to eq([ "crt_ok" ])
    end
  end

  it "does not change creatives on an older push or when the key is omitted" do
    kept = "kept-creative"
    allow(Realtoriq::RemoteFile).to receive(:fetch).and_return(kept)
    Current.set(firm_scope_bypassed: true) do
      described_class.call(project:, images: [], brochure: nil, creatives: [ creative_row("crt_keep", kept) ])
      project.update!(turbo_pushed_at: Time.current)
    end

    expect(Realtoriq::RemoteFile).not_to receive(:fetch)
    described_class.call(
      project:, images: [], brochure: nil, pushed_at: 1.hour.ago,
      creatives: [ creative_row("crt_new", "new-creative") ]
    )
    described_class.call(project:, images: [], brochure: nil)

    Current.set(firm_scope_bypassed: true) do
      expect(project.project_creatives.pluck(:external_id)).to eq([ "crt_keep" ])
    end
  end
end
