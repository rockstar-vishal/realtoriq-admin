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
      kept_row = project.project_creatives.find_by(external_id: "crt_keep")
      expect(kept_row.registration_numbers).to eq([ "P1" ])
      expect(kept_row.valid_until).to be_nil
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

  it "stores a video without downloading it, and skips a bad host" do
    image = "ok-image"
    allow(Realtoriq::RemoteFile).to receive(:fetch).and_return(image)
    lines = []
    allow(Rails.logger).to receive(:warn).and_wrap_original do |method, *args|
      lines << args.first.to_s
      method.call(*args)
    end

    Current.set(firm_scope_bypassed: true) do
      described_class.call(
        project:, images: [], brochure: nil,
        creatives: [
          creative_row("crt_ok", image),
          video_row("crt_film", "https://youtu.be/dQw4w9WgXcQ", provider: "facebook", valid_until: "2026-12-31", numbers: [ "p5" ]),
          video_row("crt_bad", "https://evil.example/watch?v=dQw4w9WgXcQ")
        ]
      )
      expect(project.project_creatives.order(:external_id).pluck(:external_id)).to eq(%w[crt_film crt_ok])
      film = project.project_creatives.find_by!(external_id: "crt_film")
      expect(film.kind).to eq("video")
      expect(film.video_url).to eq("https://youtu.be/dQw4w9WgXcQ")
      expect(film.video_provider).to eq("youtube")
      expect(film.valid_until).to eq(Date.new(2026, 12, 31))
      expect(film.registration_numbers).to eq([ "P5" ])
      expect(film.file).not_to be_attached
    end
    logged = lines.find { |line| line.include?("crt_bad") }
    expect(logged).to include(project.code)
    expect(logged).not_to include("evil.example")
    expect(logged).not_to include("http")
  end

  it "drops the file when an image becomes a video, and downloads when a video becomes a file" do
    fetches = []
    allow(Realtoriq::RemoteFile).to receive(:fetch) do
      fetches << true
      fetches.size == 1 ? "front-image" : "fresh-image"
    end
    firm = create(:firm, status: :active)
    Current.set(firm_scope_bypassed: true) do
      described_class.call(project:, images: [], brochure: nil, creatives: [ creative_row("crt_keep", "front-image") ])
      row = project.project_creatives.find_by!(external_id: "crt_keep")
      Current.set(firm:) do
        copy = PersonalisedCreative.create!(project_creative: row, firm:, fingerprint: "stamp")
        copy.file.attach(io: StringIO.new("personal"), filename: "personal.png", content_type: "image/png")
      end
    end

    Current.set(firm_scope_bypassed: true) do
      described_class.call(
        project:, images: [], brochure: nil,
        creatives: [ video_row("crt_keep", "https://www.youtube.com/shorts/dQw4w9WgXcQ") ]
      )
      row = project.project_creatives.find_by!(external_id: "crt_keep")
      expect(row.kind).to eq("video")
      expect(row.file).not_to be_attached
      expect(PersonalisedCreative.across_firms.where(project_creative_id: row.id)).to be_empty
      expect(fetches.size).to eq(1)
    end

    Current.set(firm_scope_bypassed: true) do
      described_class.call(
        project:, images: [], brochure: nil,
        creatives: [ creative_row("crt_keep", "fresh-image", title: "Front again") ]
      )
      row = project.project_creatives.find_by!(external_id: "crt_keep")
      expect(row.kind).to eq("image")
      expect(row.video_url).to be_nil
      expect(row.video_provider).to be_nil
      expect(row.file.blob.checksum).to eq(checksum("fresh-image"))
      expect(fetches.size).to eq(2)
    end
  end

  it "keeps an existing video when a later push rejects its link" do
    Current.set(firm_scope_bypassed: true) do
      described_class.call(
        project:, images: [], brochure: nil,
        creatives: [ video_row("crt_film", "https://youtu.be/dQw4w9WgXcQ") ]
      )
      described_class.call(
        project:, images: [], brochure: nil,
        creatives: [ video_row("crt_film", "https://evil.example/watch?v=nope", title: "Renamed", position: 4, numbers: [ "p9" ]) ]
      )
      row = project.project_creatives.find_by!(external_id: "crt_film")
      expect(row.kind).to eq("video")
      expect(row.video_url).to eq("https://youtu.be/dQw4w9WgXcQ")
      expect(row.video_provider).to eq("youtube")
      expect(row.title).to eq("Renamed")
      expect(row.position).to eq(4)
      expect(row.registration_numbers).to eq([ "P9" ])
    end
  end

  it "keeps an image and its copies when a video link for the same id is rejected" do
    allow(Realtoriq::RemoteFile).to receive(:fetch).and_return("front-image")
    firm = create(:firm, status: :active)
    Current.set(firm_scope_bypassed: true) do
      described_class.call(project:, images: [], brochure: nil, creatives: [ creative_row("crt_keep", "front-image") ])
      row = project.project_creatives.find_by!(external_id: "crt_keep")
      Current.set(firm:) do
        copy = PersonalisedCreative.create!(project_creative: row, firm:, fingerprint: "stamp")
        copy.file.attach(io: StringIO.new("personal"), filename: "personal.png", content_type: "image/png")
      end
      described_class.call(
        project:, images: [], brochure: nil,
        creatives: [ video_row("crt_keep", "https://evil.example/nope") ]
      )
      row.reload
      expect(row.kind).to eq("image")
      expect(row.file).to be_attached
      expect(row.video_url).to be_nil
      expect(PersonalisedCreative.across_firms.where(project_creative_id: row.id).count).to eq(1)
    end
  end

  it "keeps the stored valid_until when the push sends a date that is not ISO" do
    allow(Realtoriq::RemoteFile).to receive(:fetch).and_return("front-image")
    lines = warning_lines
    Current.set(firm_scope_bypassed: true) do
      described_class.call(
        project:, images: [], brochure: nil,
        creatives: [ creative_row("crt_keep", "front-image").merge("valid_until" => "2026-12-31") ]
      )
      described_class.call(
        project:, images: [], brochure: nil,
        creatives: [ creative_row("crt_keep", "front-image").merge("valid_until" => "31/12/2026") ]
      )
      expect(project.project_creatives.find_by!(external_id: "crt_keep").valid_until).to eq(Date.new(2026, 12, 31))
    end
    expect(lines.join).to include("valid until was not a date")
    expect(lines.join).not_to include("31/12/2026")
  end

  it "does not create a creative whose valid_until is not a date, and still stores the others" do
    allow(Realtoriq::RemoteFile).to receive(:fetch).and_return("ok-image")
    lines = warning_lines
    Current.set(firm_scope_bypassed: true) do
      described_class.call(
        project:, images: [], brochure: nil,
        creatives: [
          creative_row("crt_ok", "ok-image"),
          creative_row("crt_bad_date", "unused").merge("valid_until" => "not-a-date")
        ]
      )
      expect(project.project_creatives.pluck(:external_id)).to eq([ "crt_ok" ])
    end
    expect(lines.join).to include("crt_bad_date")
    expect(lines.join).to include("valid until was not a date")
    expect(lines.join).not_to include("not-a-date")
  end

  it "applies a valid valid_until when the file download fails" do
    allow(Realtoriq::RemoteFile).to receive(:fetch).and_return("front-image")
    Current.set(firm_scope_bypassed: true) do
      described_class.call(project:, images: [], brochure: nil, creatives: [ creative_row("crt_keep", "front-image") ])
      allow(Realtoriq::RemoteFile).to receive(:fetch).and_raise(Realtoriq::RemoteFile::TypeError)
      described_class.call(
        project:, images: [], brochure: nil,
        creatives: [ creative_row("crt_keep", "replacement").merge("valid_until" => "2026-06-15") ]
      )
      row = project.project_creatives.find_by!(external_id: "crt_keep")
      expect(row.valid_until).to eq(Date.new(2026, 6, 15))
      expect(row.file.blob.checksum).to eq(checksum("front-image"))
    end
  end

  def warning_lines
    lines = []
    allow(Rails.logger).to receive(:warn).and_wrap_original do |method, *args|
      lines << args.first.to_s
      method.call(*args)
    end
    lines
  end

  def video_row(id, url, provider: "youtube", title: "Walkthrough", valid_until: nil, numbers: [], position: 2)
    {
      "id" => id,
      "title" => title,
      "position" => position,
      "kind" => "video",
      "video_url" => url,
      "video_provider" => provider,
      "valid_until" => valid_until,
      "registration_numbers" => numbers,
      "tags" => [ "ignored" ]
    }
  end
end
