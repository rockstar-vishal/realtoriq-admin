# frozen_string_literal: true

require "rails_helper"
require "vips"
require "zip"
require "rqrcode"

module MarketingKitOpenFailure
  def open(...)
    names = Thread.current[:marketing_kit_fail_open]
    raise ArgumentError, "https://files.example/missing-object" if names&.include?(filename.to_s)

    super
  end
end
ActiveStorage::Blob.prepend(MarketingKitOpenFailure)

RSpec.describe "Marketing creatives and microsite kits" do
  include ActiveJob::TestHelper

  after { Thread.current[:marketing_kit_fail_open] = nil }

  let(:plan) { create(:plan) }
  let(:firm) { create(:firm, status: :active, name: "Sethi Realty", rera_number: "A51900000001") }
  let!(:subscription) { create(:subscription, firm:, plan:) }
  let!(:user) { create(:user, :super_admin, firm:) }
  let!(:mobile) { create(:contact_channel, :mobile, :verified, firm:, value: "+919820155001") }
  let!(:whatsapp) { create(:contact_channel, :whatsapp, :verified, firm:, value: "+919811122233") }
  let(:city) { create(:city, name: "Mumbai", state: "Maharashtra") }
  let(:locality) { create(:locality, city:, name: "Worli") }
  let(:builder) { create(:builder, firm: nil, name: "Lodha") }
  let(:typology) { create(:typology, name: "2 BHK") }
  let(:catalog) do
    Current.set(firm_scope_bypassed: true) do
      create(:project, :catalog, firm: nil, name: "Harbour One", builder:, city:, locality:,
        external_ref: "PR4F2A9C", rera_number: "P51800000001, P51800000002",
        starting_budget: 15_500_000, address: "12 Sea Face",
        rm_name: "RMNAMELEAK", rm_contact: "9000000001", company_code: "COMPANYCODELEAK",
        brokerage_percent: 7.25,
        rera_registrations: [
          { "number" => "P51800000001", "label" => "Tower A", "maharera_url" => "https://maharerait.maharashtra.gov.in/project/view/54321" },
          { "number" => "P51800000002", "label" => "Tower B", "maharera_url" => "https://maharerait.maharashtra.gov.in/project/view/54322" }
        ])
    end
  end
  let!(:creative) do
    row = ProjectCreative.create!(
      project: catalog, external_id: "crt_front", title: "Front elevation", kind: "image",
      position: 1, registration_numbers: [], checksum: "pending"
    )
    row.file.attach(io: StringIO.new(png_bytes(800, 200)), filename: "front.png", content_type: "image/png")
    row.file.blob.analyze
    row.update!(checksum: row.file.blob.checksum)
    row
  end

  def auth(as: user)
    post "/api/v1/auth/otp", params: { mobile: as.mobile }, as: :json
    request_id = response.parsed_body["request_id"]
    post "/api/v1/auth/verify",
      params: { request_id:, code: Notifications::Deliverer.current.last.code }, as: :json
    { "Authorization" => "Bearer #{response.parsed_body["access_token"]}" }
  end

  def png_bytes(width, height, color: [ 10, 40, 80 ])
    Vips::Image.black(width, height).new_from_image(color).copy(interpretation: :srgb).write_to_buffer(".png")
  end

  def pdf_text(bytes)
    file = Tempfile.new([ "creative", ".pdf" ])
    file.binmode
    file.write(bytes)
    file.close
    IO.popen([ "pdftotext", "-layout", file.path, "-" ], &:read)
  end

  def pdf_text_page(bytes, page)
    file = Tempfile.new([ "creative", ".pdf" ])
    file.binmode
    file.write(bytes)
    file.close
    IO.popen([ "pdftotext", "-layout", "-f", page.to_s, "-l", page.to_s, file.path, "-" ], &:read)
  end

  before { create(:project_typology, project: catalog, typology:, starting_carpet_sqft: 712, starting_price: 15_500_000) }

  it "returns registrations, creatives and whether this firm can share" do
    headers = auth
    get "/api/v1/projects/#{catalog.id}", headers: headers
    body = response.parsed_body["project"]
    expect(body["rera_registrations"]).to eq([
      { "number" => "P51800000001", "label" => "Tower A", "maharera_url" => "https://maharerait.maharashtra.gov.in/project/view/54321" },
      { "number" => "P51800000002", "label" => "Tower B", "maharera_url" => "https://maharerait.maharashtra.gov.in/project/view/54322" }
    ])
    expect(body["creatives"].first).to include(
      "id" => creative.id, "title" => "Front elevation", "kind" => "image", "page_count" => nil,
      "registration_numbers" => [], "width" => 800, "height" => 200
    )
    expect(body["creatives"].first["thumb_url"]).to be_present
    expect(body["marketing"]).to eq("can_share" => true, "blocked_reason" => nil)

    own = create(:project, firm:, name: "My Harbour", builder:, city:, rera_number: "P100, P200")
    get "/api/v1/projects/#{own.id}", headers: headers
    mine = response.parsed_body["project"]
    expect(mine["creatives"]).to eq([])
    expect(mine["rera_registrations"]).to eq([
      { "number" => "P100", "label" => nil, "maharera_url" => nil },
      { "number" => "P200", "label" => nil, "maharera_url" => nil }
    ])

    copy = create(:project, firm:, name: "Harbour Copy", builder:, city:, external_ref: catalog.external_ref, rera_number: "P999")
    get "/api/v1/projects/#{copy.id}", headers: headers
    copied = response.parsed_body["project"]
    expect(copied["creatives"].map { |row| row["id"] }).to eq([ creative.id ])
    expect(copied["rera_registrations"].map { |row| row["number"] }).to eq(%w[P51800000001 P51800000002])

    firm.update!(rera_number: nil)
    get "/api/v1/projects/#{catalog.id}", headers: headers
    expect(response.parsed_body.dig("project", "marketing")).to eq(
      "can_share" => false, "blocked_reason" => "firm_rera_missing"
    )

    firm.update!(rera_number: "A51900000001")
    firm.contact_channels.update_all(verification_state: "unverified")
    get "/api/v1/projects/#{catalog.id}", headers: headers
    expect(response.parsed_body.dig("project", "marketing")).to eq(
      "can_share" => false, "blocked_reason" => "firm_phone_missing"
    )
  end

  it "adds a footer without covering the artwork, and caches it until the firm changes" do
    file = Tempfile.new([ "source", ".png" ])
    file.binmode
    file.write(png_bytes(800, 200))
    file.flush
    source = Vips::Image.new_from_file(file.path)
    composed = Marketing::FooterImage.compose(
      file.path, firm:, project: catalog, numbers: %w[P51800000001 P51800000002]
    )
    top = composed.image.crop(0, 0, source.width, source.height)
    prepared = Marketing::FooterImage.prepare(source)
    expect(top.write_to_memory).to eq(prepared.write_to_memory)
    expect(composed.image.width).to eq(source.width)
    expect(composed.image.height).to eq(source.height + composed.band_height)
    drawn = composed.lines.join(" ")
    expect(drawn).to include(firm.name, "+91 98201 55001", "+91 98111 22233", "A51900000001", "P51800000001", "P51800000002")
    expect(drawn).to include("MahaRERA Agent Reg. No. A51900000001", "Project Reg. No. P51800000001")

    headers = auth
    lines = []
    allow(Marketing::FooterImage).to receive(:compose).and_wrap_original do |method, *args, **kwargs|
      result = method.call(*args, **kwargs)
      lines << result.lines.join(" ")
      result
    end

    post "/api/v1/projects/#{catalog.id}/creatives/#{creative.id}/personalised", headers: headers
    expect(response).to have_http_status(:ok)
    file = response.parsed_body["file"]
    expect(file["content_type"]).to eq("image/jpeg")
    expect(file["filename"]).to include(firm.slug)
    expect(file["url"]).to include("/rails/active_storage/blobs/proxy/")
    get URI.parse(file["url"]).path, headers: { "Origin" => "http://localhost:3000" }
    expect(response).to have_http_status(:ok)
    expect(response.media_type).to eq("image/jpeg")
    expect(response.headers["Access-Control-Allow-Origin"]).to eq("http://localhost:3000")
    saved = PersonalisedCreative.across_firms.find_by!(firm:, project_creative: creative)
    image = Vips::Image.new_from_file(ActiveStorage::Blob.service.path_for(saved.file.blob.key))
    expect(image.width).to eq(800)
    expect(image.height).to be > 200

    post "/api/v1/projects/#{catalog.id}/creatives/#{creative.id}/personalised", headers: headers
    expect(response).to have_http_status(:ok)
    expect(Marketing::FooterImage).to have_received(:compose).once
    expect(PersonalisedCreative.across_firms.where(firm:, project_creative: creative).count).to eq(1)

    mobile.update!(value: "+919900011122")
    post "/api/v1/projects/#{catalog.id}/creatives/#{creative.id}/personalised", headers: headers
    expect(response).to have_http_status(:ok)
    expect(lines.last).to include("+91 99000 11122")
    expect(PersonalisedCreative.across_firms.where(firm:, project_creative: creative).count).to eq(1)

    post "/api/v1/projects/#{catalog.id}/creatives/#{SecureRandom.uuid}/personalised", headers: headers
    expect(response).to have_http_status(:not_found)
  end

  it "refuses a firm that cannot be printed on the creative" do
    headers = auth
    firm.update!(rera_number: nil)
    post "/api/v1/projects/#{catalog.id}/creatives/#{creative.id}/personalised", headers: headers
    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body.dig("error", "code")).to eq("firm_rera_missing")
    expect(response.parsed_body.dig("error", "message")).to eq(Marketing::Eligibility::MESSAGES["firm_rera_missing"])

    firm.update!(rera_number: "A51900000001")
    firm.contact_channels.update_all(verification_state: "unverified")
    post "/api/v1/projects/#{catalog.id}/creatives/#{creative.id}/personalised", headers: headers
    expect(response.parsed_body.dig("error", "code")).to eq("firm_phone_missing")
    expect(response.parsed_body.dig("error", "message")).to eq(Marketing::Eligibility::MESSAGES["firm_phone_missing"])
    expect(PersonalisedCreative.across_firms.where(firm:).count).to eq(0)
  end

  it "extends every pdf page with selectable footer text" do
    bytes = Prawn::Document.new(page_size: [ 500, 400 ], margin: 36) do |pdf|
      pdf.text "ORIGINAL-BODY"
      pdf.start_new_page
      pdf.text "ORIGINAL-BODY"
    end.render
    creative.file.attach(io: StringIO.new(bytes), filename: "front.pdf", content_type: "application/pdf")
    creative.update!(kind: "pdf", page_count: 2, checksum: creative.file.blob.checksum)

    original = CombinePDF.parse(bytes).pages.map { |page| stream_bodies(page) }
    result = Marketing::PersonaliseCreative.call(creative:, firm:)
    rendered = result.payload
    expect(rendered[:content_type]).to eq("application/pdf")
    file = PersonalisedCreative.across_firms.find_by!(firm:, project_creative: creative).file.download
    text = pdf_text(file)
    expect(text).to include("ORIGINAL-BODY", firm.name, "+91 98201 55001", "A51900000001", "P51800000001", "P51800000002")
    pdf = CombinePDF.parse(file)
    expect(pdf.pages.size).to eq(2)
    pdf.pages.each_with_index do |page, index|
      box = page.mediabox.map(&:to_f)
      expect(box[3] - box[1]).to be > 400
      expect(image_on_page?(page)).to be(true)
      original[index].each { |body| expect(stream_bodies(page)).to include(body) }
      page_text = pdf_text_page(file, index + 1)
      expect(page_text).to include(firm.name, "A51900000001")
    end
  end

  it "builds a kit zip for this firm only" do
    other = create(:firm, name: "OTHERFIRMLEAK")
    catalog.photos.attach(io: StringIO.new(png_bytes(40, 30)), filename: "site.png", content_type: "image/png")
    firm.logo.attach(io: StringIO.new(png_bytes(16, 16, color: [ 0, 0, 0 ])), filename: "logo.png", content_type: "image/png")
    headers = auth

    post "/api/v1/projects/#{catalog.id}/microsite_kit", headers: headers
    expect(response).to have_http_status(:accepted)
    expect(response.parsed_body).to eq("kit" => { "status" => "preparing" })

    perform_enqueued_jobs
    get "/api/v1/projects/#{catalog.id}/microsite_kit", headers: headers
    body = response.parsed_body["kit"]
    expect(body["status"]).to eq("ready"), response.body
    expect(body["filename"]).to end_with("-microsite-kit.zip")
    expect(body["url"]).to include("/rails/active_storage/blobs/proxy/")
    expect(body["download_url"]).to include("/rails/active_storage/blobs/redirect/")
    expect(body["download_url"]).to include("disposition=attachment")
    get URI.parse(body["url"]).path, headers: { "Origin" => "http://localhost:3000" }
    expect(response).to have_http_status(:ok)
    expect(response.media_type).to eq("application/zip")
    expect(response.headers["Access-Control-Allow-Origin"]).to eq("http://localhost:3000")
    expect(body["byte_size"]).to be > 0
    expect(body["prepared_on"]).to eq(
      Time.current.in_time_zone("Asia/Kolkata").then { |time| "#{time.day} #{time.strftime("%b %Y")}" }
    )

    kit = MicrositeKit.across_firms.find_by!(firm:)
    file = Tempfile.new([ "kit", ".zip" ])
    file.binmode
    file.write(kit.file.download)
    file.close
    names = []
    html = nil
    Zip::File.open(file.path) do |zip|
      names = zip.map(&:name)
      html = zip.read("index.html")
      copy = zip.read("copy.txt")
      expect(html).not_to include("{{")
      expect(html).to include(firm.name, "P51800000001", "P51800000002")
      expect(copy).to include("Marketed by #{firm.name}")
      packed = names.map { |name| zip.read(name) }.join("\n")
      expect(packed).not_to include("RMNAMELEAK")
      expect(packed).not_to include("COMPANYCODELEAK")
      expect(packed).not_to include(other.name)
      [ "P51800000001", "P51800000002" ].each do |number|
        url = catalog.rera_registrations.find { |row| row["number"] == number }["maharera_url"]
        svg_name = "assets/rera-qr-#{number}.svg"
        expect(zip.read(svg_name)).to eq(RQRCode::QRCode.new(url).as_svg)
      end
    end
    expect(names).to include("index.html", "privacy.html", "GUIDE.html", "copy.txt", "assets/hero.jpg", "assets/photo-01.jpg", "assets/logo.png")
    expect(names.any? { |name| name.start_with?("creatives/") }).to be(true)

    post "/api/v1/projects/#{catalog.id}/microsite_kit", headers: headers
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig("kit", "status")).to eq("ready")
    expect(response.parsed_body.dig("kit", "url")).to include("/rails/active_storage/blobs/proxy/")
    expect(response.parsed_body.dig("kit", "download_url")).to include("/rails/active_storage/blobs/redirect/")
    expect(response.parsed_body.dig("kit", "download_url")).to include("disposition=attachment")
  end

  it "starts a fresh kit when one has been preparing for more than 10 minutes" do
    headers = auth
    fingerprint = Marketing::KitFingerprint.call(firm:, project: catalog)
    stale = MicrositeKit.create!(project: catalog, firm:, fingerprint:, status: "preparing")
    stale.update_columns(created_at: 15.minutes.ago, updated_at: 15.minutes.ago)

    expect {
      post "/api/v1/projects/#{catalog.id}/microsite_kit", headers: headers
    }.to have_enqueued_job(Marketing::BuildMicrositeKitJob)

    expect(response).to have_http_status(:accepted)
    expect(MicrositeKit.across_firms.find(stale.id).status).to eq("failed")
    fresh = MicrositeKit.across_firms.where(firm:, project: catalog, status: "preparing")
    expect(fresh.count).to eq(1)
    expect(fresh.pick(:id)).not_to eq(stale.id)
  end

  it "does not return a failed kit's exception text" do
    headers = auth
    MicrositeKit.create!(
      project: catalog, firm:, fingerprint: "failed-kit", status: "failed",
      error_message: "NoMethodError: secret boom"
    )
    get "/api/v1/projects/#{catalog.id}/microsite_kit", headers: headers
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig("kit", "message")).to eq("Couldn't Prepare the Kit.")
    expect(response.body).not_to include("secret boom")
    expect(response.body).not_to include("NoMethodError")
  end

  it "loads five creatives in the same number of queries as one" do
    headers = auth
    get "/api/v1/projects/#{catalog.id}", headers: headers
    one = count_sql_queries { get "/api/v1/projects/#{catalog.id}", headers: headers }

    4.times do |index|
      row = ProjectCreative.create!(
        project: catalog, external_id: "crt_extra_#{index}", title: "Frame #{index}", kind: "image",
        position: index + 2, registration_numbers: [], checksum: "pending"
      )
      row.file.attach(io: StringIO.new(png_bytes(80, 40)), filename: "frame-#{index}.png", content_type: "image/png")
      row.file.blob.analyze
      row.update!(checksum: row.file.blob.checksum)
    end

    five = count_sql_queries { get "/api/v1/projects/#{catalog.id}", headers: headers }
    expect(five).to eq(one)
    expect(response.parsed_body.dig("project", "creatives").size).to eq(5)
  end

  it "keeps the kit when one photo cannot be read" do
    attach_photo("one.png", [ 220, 10, 10 ])
    bad = attach_photo("two.png", [ 10, 220, 10 ])
    attach_photo("three.png", [ 10, 10, 220 ])
    lines = record_warnings
    fail_open_for("two.png")

    _kit, names, files = built_kit
    expect(names).to include("assets/photo-01.jpg", "assets/photo-02.jpg", "assets/hero.jpg")
    expect(names).not_to include("assets/photo-03.jpg")
    expect(files["assets/hero.jpg"]).to eq(files["assets/photo-01.jpg"])
    expect(jpeg_pixel(files["assets/photo-01.jpg"])[0]).to be > 180
    expect(jpeg_pixel(files["assets/photo-02.jpg"])[2]).to be > 180
    expect(skip_lines(lines)).to eq([ skip_line(bad) ])
  end

  it "builds a kit with no gallery when every photo fails" do
    first = attach_photo("one.png", [ 220, 10, 10 ])
    second = attach_photo("two.png", [ 10, 220, 10 ])
    lines = record_warnings
    fail_open_for("one.png", "two.png")

    _kit, names, files = built_kit
    html = files.fetch("index.html")
    expect(html).not_to include("{{")
    expect(html).not_to include('id="gallery"')
    expect(names.grep(/photo-|hero/)).to eq([])
    expect(names).to include("index.html", "privacy.html", "GUIDE.html", "copy.txt")
    ordered = [ first, second ].sort_by { |attachment| [ attachment.created_at, attachment.id ] }
    expect(skip_lines(lines)).to eq(ordered.map { |attachment| skip_line(attachment) })
  end

  it "keeps the other creatives when one cannot be personalised" do
    other = ProjectCreative.create!(
      project: catalog, external_id: "crt_back", title: "Rear elevation", kind: "image",
      position: 2, registration_numbers: [], checksum: "pending"
    )
    other.file.attach(io: StringIO.new(png_bytes(400, 200)), filename: "back.png", content_type: "image/png")
    other.update!(checksum: other.file.blob.checksum)
    lines = record_warnings
    allow(Marketing::PersonaliseCreative).to receive(:call).and_wrap_original do |method, **kwargs|
      raise ArgumentError, "https://files.example/missing-object" if kwargs[:creative].id == other.id

      method.call(**kwargs)
    end

    _kit, names, = built_kit
    expect(names.grep(%r{\Acreatives/}).size).to eq(1)
    expect(skip_lines(lines)).to eq([ skip_line(other.file.attachment) ])
  end

  it "leaves the logo out when it cannot be read" do
    firm.logo.attach(io: StringIO.new(png_bytes(16, 16, color: [ 0, 0, 0 ])), filename: "logo.png", content_type: "image/png")
    perform_enqueued_jobs
    lines = record_warnings
    fail_open_for("logo.png")

    _kit, names, files = built_kit
    html = files.fetch("index.html")
    expect(names).not_to include("assets/logo.png")
    expect(html).not_to include("assets/logo.png")
    expect(html).not_to include('src=""')
    expect(html).to include('href="data:,"')
    expect(skip_lines(lines)).to eq([ skip_line(firm.logo.attachment) ])
  end

  def attach_photo(filename, color)
    catalog.photos.attach(io: StringIO.new(png_bytes(40, 30, color:)), filename:, content_type: "image/png")
    perform_enqueued_jobs
    catalog.photos.attachments.detect { |attachment| attachment.blob.filename.to_s == filename }
  end

  def fail_open_for(*filenames)
    Thread.current[:marketing_kit_fail_open] = filenames.map(&:to_s)
  end

  def record_warnings
    lines = []
    allow(Rails.logger).to receive(:warn).and_wrap_original do |method, *args, **kwargs|
      lines << args.first.to_s
      method.call(*args, **kwargs)
    end
    lines
  end

  def skip_lines(lines)
    found = lines.grep(/\AMicrosite kit skipped /)
    expect(found.join).not_to include("http")
    expect(found.join).not_to include("files.example")
    found
  end

  def skip_line(attachment)
    "Microsite kit skipped #{catalog.code} attachment #{attachment.id}: ArgumentError"
  end

  def built_kit
    headers = auth
    post "/api/v1/projects/#{catalog.id}/microsite_kit", headers: headers
    perform_enqueued_jobs(only: Marketing::BuildMicrositeKitJob)
    get "/api/v1/projects/#{catalog.id}/microsite_kit", headers: headers
    expect(response.parsed_body.dig("kit", "status")).to eq("ready")
    kit = MicrositeKit.across_firms.find_by!(firm:, project: catalog)
    file = Tempfile.new([ "kit", ".zip" ])
    file.binmode
    file.write(kit.file.download)
    file.close
    names = []
    files = {}
    Zip::File.open(file.path) do |zip|
      names = zip.map(&:name)
      names.each { |name| files[name] = zip.read(name) }
    end
    [ kit, names, files ]
  end

  def jpeg_pixel(bytes)
    Vips::Image.new_from_buffer(bytes, "").getpoint(0, 0).map(&:round)
  end

  def stream_bodies(page)
    bodies = []
    walk = lambda do |obj, depth|
      return if obj.nil? || depth > 8

      case obj
      when Hash
        body = obj[:raw_stream_content]
        bodies << body if body.is_a?(String) && body.present?
        obj.each { |key, value| walk.call(value, depth + 1) unless key == :Parent }
      when Array
        obj.each { |value| walk.call(value, depth + 1) }
      end
    end
    walk.call(page[:Contents], 0)
    bodies.uniq
  end

  def image_on_page?(page)
    found = false
    walk = lambda do |obj, depth|
      return if found || obj.nil? || depth > 8

      case obj
      when Hash
        found = true if obj[:Subtype] == :Image
        obj.each { |key, value| walk.call(value, depth + 1) unless key == :Parent }
      when Array
        obj.each { |value| walk.call(value, depth + 1) }
      end
    end
    walk.call(page[:Resources], 0)
    found
  end
end
