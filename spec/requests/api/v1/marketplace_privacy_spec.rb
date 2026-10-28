# frozen_string_literal: true

require "rails_helper"

# Canaries are unique strings planted on one firm's records. The other firm's
# raw response must not contain them, whatever the JSON key is called.
RSpec.describe "Marketplace privacy canaries" do
  after do
    Current.reset
    AnchorMatching.delete_all
    NearbyMatching.delete_all
  end

  [ true, false ].each do |anchors_on|
    it "hides the other firm's private fields when anchor matching is #{anchors_on ? "on" : "off"}" do
      prepare(anchors_on)
      buyer_cannot_see_owner
      owner_cannot_see_buyer
      review_demo_sees_neither
    end
  end

  def prepare(anchors_on)
    @anchors_on = anchors_on
    @tokens = {}
    @distances = []
    NearbyMatching.enable!
    if anchors_on
      AnchorMatching.enable!
      AnchorMatching.set_radius!(6_000)
    else
      AnchorMatching.delete_all
    end

    @plan = create(:plan)
    @ready = create(:property_type, name: "Ready possession")
    @status = create(:lead_status, :new_lead)
    @typology = create(:typology, name: "2 BHK")
    @city = create(:city, name: "Mumbai", state: "Maharashtra")
    @locality = create(:locality, city: @city, name: "Worli")

    @firm_a = create(:firm, status: :active, name: "Owner Realty", legal_name: "Owner Realty Pvt Ltd",
      rera_number: "A51000000011", primary_contact_name: "Owner Contact")
    @firm_b = create(:firm, status: :active, name: "Buyer Realty", legal_name: "Buyer Realty Pvt Ltd",
      rera_number: "A51000000022", primary_contact_name: "Buyer Contact")
    @demo = create(:firm, status: :active, review_demo: true, name: "Review Desk",
      legal_name: "Review Desk Pvt Ltd", rera_number: "A51000000033", primary_contact_name: "Review Contact")
    [ @firm_a, @firm_b, @demo ].each { |firm| create(:subscription, firm:, plan: @plan) }

    @manager_a = member(@firm_a, :manager, "Owner Manager", "+919810000001")
    @agent_a = member(@firm_a, :agent, "Owner Agent", "+919810000002")
    @admin_a = member(@firm_a, :super_admin, "Owner Admin", "+919810000003")
    @manager_b = member(@firm_b, :manager, "Buyer Manager", "+919810000011")
    @agent_b = member(@firm_b, :agent, "Buyer Agent", "+919810000012")
    @admin_b = member(@firm_b, :super_admin, "Buyer Admin", "+919810000013")
    @demo_manager = member(@demo, :manager, "Review Manager", "+919810000021")

    @listing = create(:property, firm: @firm_a, typology: @typology, city: @city, locality: @locality,
      listed_on_marketplace: true, status: "available", price: 11_200_000, carpet_area_sqft: 640,
      building_name: "ZQX Canary Tower", address: "ZQX Canary Road",
      description: "ZQX canary description", confidential_note: "ZQX canary note",
      floor_band: "higher", lat: BigDecimal("19.123457"), lng: BigDecimal("72.876543"))
    @listing.photos.attach(io: StringIO.new("canary-bytes"), filename: "zqx-canary.jpg", content_type: "image/jpeg")
    blob = @listing.photos.blobs.first
    @blob_key = blob.key
    @photo_name = blob.filename.to_s
    expect(@photo_name).to eq("zqx-canary.jpg")

    # typology_id and locality_id are NOT NULL. Blank names are what make
    # Property#title fall back to the building name.
    bare_type = create(:typology, name: "Bare Flat", code: "bare_flat")
    bare_city = create(:city, name: "Nashik", state: "Maharashtra")
    bare_place = create(:locality, city: bare_city, name: "College Road")
    @bare = create(:property, firm: @firm_a, typology: bare_type, city: bare_city, locality: bare_place,
      listed_on_marketplace: true, status: "available", price: 11_300_000,
      building_name: "ZQX Bare Tower")
    bare_type.update_column(:name, "")
    bare_place.update_column(:name, "")

    near_lat, near_lng = Inventory::Geo.offset(@listing.lat, @listing.lng, north_m: 566, east_m: 566)
    @owner_lead = place_lead(@firm_a, @agent_a, name: "ZQX Owner Client", mobile: "9876500011",
      email: "zqx-owner@example.com", budget: 9_876_543, notes: "ZQX owner notes",
      label: "ZQX Owner Office", address: "ZQX Owner Road", lat: BigDecimal("18.456789"), lng: BigDecimal("73.654321"))
    @b_secret = []
    # Budgets sit above the listing price so they still score, and they are not
    # the listing price, which the owner is allowed to see on their own card.
    @local_lead = buyer_lead("ZQX B Local Client", "9811100011", "zqx-b-local@example.com", 15_551_111,
      "ZQX B Local Office", "ZQX B Local Road", "ZQX B local notes", BigDecimal("18.211111"), BigDecimal("73.211111"))
    @near_lead = buyer_lead("ZQX B Near Client", "9811100022", "zqx-b-near@example.com", 15_552_222,
      "ZQX B Near Office", "ZQX B Near Road", "ZQX B near notes", near_lat, near_lng)
    @anchor_lead = buyer_lead("ZQX B Anchor Client", "9811100033", "zqx-b-anchor@example.com", 15_553_333,
      "ZQX B Anchor Office", "ZQX B Anchor Road", "ZQX B anchor notes", BigDecimal("18.311111"), BigDecimal("73.311111"))
    @book_lead = buyer_lead("ZQX B Book Client", "9811100044", "zqx-b-book@example.com", 15_554_444,
      "ZQX B Book Office", "ZQX B Book Road", "ZQX B book notes", BigDecimal("18.411111"), BigDecimal("73.411111"))
    @demo_lead = place_lead(@demo, @demo_manager, name: "Review Buyer", mobile: "9811100088",
      email: "review-buyer@example.com", budget: 11_200_000, notes: "Review notes",
      label: "Review Office", address: "Review Road", lat: BigDecimal("18.511111"), lng: BigDecimal("73.511111"))

    @listing.reload
    @owner_lead.reload
    [ @local_lead, @near_lead, @anchor_lead, @book_lead ].each(&:reload)
    pins = [
      @listing.lat, @listing.lng, @owner_lead.near_lat, @owner_lead.near_lng,
      @local_lead.near_lat, @local_lead.near_lng, @near_lead.near_lat, @near_lead.near_lng,
      @anchor_lead.near_lat, @anchor_lead.near_lng, @book_lead.near_lat, @book_lead.near_lng
    ]
    assert_distinct_pins(pins)
    metres = Inventory::Geo.distance_m(@listing.lat, @listing.lng, @near_lead.near_lat, @near_lead.near_lng)
    expect(metres).to be_between(700, 900)

    @a_secret = [
      "ZQX Canary Tower", "ZQX Canary Road", "ZQX canary description", "ZQX canary note",
      "ZQX Bare Tower", "ZQX Owner Client", "ZQX owner notes", "ZQX Owner Office", "ZQX Owner Road",
      "zqx-owner@example.com", "zqx-canary.jpg", @blob_key, "9876500011", "9876543", @owner_lead.id,
      pin_fragment(@listing.lat), pin_fragment(@listing.lng),
      pin_fragment(@owner_lead.near_lat), pin_fragment(@owner_lead.near_lng)
    ].map(&:to_s)

    Current.firm = @firm_b
    @anchor_lead.lead_properties.create!(property: @listing, firm: @firm_b)
    visit = Leads::RecordVisit.new(
      lead: @anchor_lead, actor: @manager_b,
      attributes: { visited_on: "2026-10-20", property_ids: [ @listing.id ] }
    ).call
    expect(visit.ok?).to be(true)

    Current.firm = @firm_a
    Matches::CurateFirm.call(firm: @firm_a, announce: false)
    Current.firm = @firm_b
    Matches::CurateFirm.call(firm: @firm_b, announce: false)
    Current.reset
    @local_mapped = false
    @booking_id = nil
  end

  def buyer_cannot_see_owner
    as_viewer(@a_secret, @b_secret) do
      [ @manager_b, @agent_b ].each do |user|
        directory(user)
        call_api(:get, "/api/v1/properties/#{@listing.id}/marketplace", user, status: :ok)
        call_api(:get, "/api/v1/properties/#{@bare.id}/marketplace", user, status: :ok)
        expect(response.parsed_body.dig("property", "title")).to eq("Listing")
        call_api(:get, "/api/v1/properties/#{@listing.id}", user, status: :not_found)
        call_api(:get, "/api/v1/properties/#{@bare.id}", user, status: :not_found)
        call_api(:get, "/api/v1/properties", user, status: :ok)
        call_api(:post, "/api/v1/properties/#{@listing.id}/lead_matches", user, status: :ok)

        [ @local_lead, @near_lead, @anchor_lead, @book_lead ].each do |lead|
          call_api(:post, "/api/v1/leads/#{lead.id}/matches", user, status: :ok)
          # The manager maps the locality lead before the agent runs, and a
          # mapped listing is left out of matches. The near lead stays unmapped.
          if lead == @near_lead || (lead == @local_lead && !@local_mapped)
            expect_listing_match
          end
          if lead == @near_lead && @anchors_on
            matched = response.parsed_body["matches"].find { |row| row["id"] == @listing.id }
            expect(matched["distance_m"]).to be_present
          end
          call_api(:post, "/api/v1/leads/#{lead.id}/matches", user, params: { q: "ZQX" }, status: :ok)
          call_api(:get, "/api/v1/leads/#{lead.id}", user, status: :ok)
        end

        map_status = @local_mapped ? :unprocessable_content : :created
        call_api(:post, "/api/v1/leads/#{@local_lead.id}/properties", user,
          params: { property_id: @listing.id }, status: map_status)
        @local_mapped = true
        call_api(:get, "/api/v1/leads/#{@local_lead.id}", user, status: :ok)
        call_api(:get, "/api/v1/leads/#{@anchor_lead.id}/visits", user, status: :ok)
        call_api(:post, "/api/v1/leads/#{@anchor_lead.id}/visits", user,
          params: { visited_on: "2026-10-21", property_ids: [ @listing.id ] }, status: :created)
        bookings_for(user)
        call_api(:get, "/api/v1/match_digest", user, status: :not_found)
        call_api(:get, "/api/v1/notifications", user, status: :ok)
        call_api(:get, "/api/v1/dashboard", user, status: :ok)
        import_listing(user)
      end
      call_api(:get, "/api/v1/match_digest", @admin_b, status: :ok)
    end
    expect(@distances).not_to be_empty if @anchors_on
  end

  def owner_cannot_see_buyer
    as_viewer(@b_secret, @a_secret) do
      [ @manager_a, @agent_a ].each do |user|
        call_api(:post, "/api/v1/properties/#{@listing.id}/lead_matches", user, status: :ok)
        expect(response.parsed_body["marketplace_matches"]).not_to be_empty
        expect(response.parsed_body["marketplace_firms"].map { |row| row["name"] }).to include("Buyer Realty")
        call_api(:get, "/api/v1/properties/#{@listing.id}", user, status: :ok)
        call_api(:get, "/api/v1/properties/#{@listing.id}/mapped_customers", user, status: :ok)
        call_api(:get, "/api/v1/properties/#{@listing.id}/visitors", user, status: :ok)
        call_api(:get, "/api/v1/match_digest", user, status: :not_found)
        call_api(:get, "/api/v1/notifications", user, status: :ok)
        call_api(:get, "/api/v1/dashboard", user, status: :ok)
      end
      call_api(:get, "/api/v1/match_digest", @admin_a, status: :ok)
    end
  end

  def review_demo_sees_neither
    as_viewer(@a_secret + @b_secret, []) do
      call_api(:get, "/api/v1/properties/marketplace", @demo_manager, status: :ok)
      ids = response.parsed_body["properties"].map { |row| row["id"] }
      expect(ids).not_to include(@listing.id, @bare.id)
      call_api(:get, "/api/v1/properties/marketplace", @demo_manager, params: { q: "ZQX" }, status: :ok)
      expect(response.parsed_body["properties"]).to eq([])
      call_api(:get, "/api/v1/properties/#{@listing.id}/marketplace", @demo_manager, status: :not_found)
      call_api(:get, "/api/v1/properties/#{@bare.id}/marketplace", @demo_manager, status: :not_found)
      call_api(:get, "/api/v1/properties/#{@listing.id}", @demo_manager, status: :not_found)
      call_api(:post, "/api/v1/properties/#{@listing.id}/lead_matches", @demo_manager, status: :not_found)
      call_api(:post, "/api/v1/leads/#{@demo_lead.id}/matches", @demo_manager, status: :ok)
      match_ids = response.parsed_body["matches"].map { |row| row["id"] }
      expect(match_ids).not_to include(@listing.id, @bare.id)
      call_api(:get, "/api/v1/leads/#{@demo_lead.id}", @demo_manager, status: :ok)
      call_api(:get, "/api/v1/match_digest", @demo_manager, status: :not_found)
      call_api(:get, "/api/v1/notifications", @demo_manager, status: :ok)
      call_api(:get, "/api/v1/dashboard", @demo_manager, status: :ok)
      call_api(:post, "/api/v1/bookings", @demo_manager, params: booking_params(@demo_lead), status: :unprocessable_content)
      expect(response.parsed_body.dig("error", "code")).to eq("listing_not_found")
    end
  end

  def directory(user)
    call_api(:get, "/api/v1/properties/marketplace", user, status: :ok)
    ids = response.parsed_body["properties"].map { |row| row["id"] }
    expect(ids).to include(@listing.id, @bare.id)
    call_api(:get, "/api/v1/properties/marketplace", user, params: { q: "Worli" }, status: :ok)
    call_api(:get, "/api/v1/properties/marketplace", user, params: { q: "ZQX" }, status: :ok)
    expect(response.parsed_body["properties"]).to eq([])
  end

  def bookings_for(user)
    if user.manager?
      if @booking_id.nil?
        call_api(:post, "/api/v1/bookings", user, params: booking_params(@book_lead), status: :created)
        @booking_id = response.parsed_body.dig("booking", "id")
        expect(response.parsed_body.dig("booking", "property", "title")).to eq("Listing")
      else
        call_api(:post, "/api/v1/bookings", user, params: booking_params(@book_lead), status: :unprocessable_content)
      end
      call_api(:get, "/api/v1/bookings", user, status: :ok)
      titles = response.parsed_body["bookings"].map { |row| row.dig("property", "title") }
      expect(titles).to include("Listing")
      call_api(:get, "/api/v1/bookings/#{@booking_id}", user, status: :ok)
      expect(response.parsed_body.dig("booking", "property", "title")).to eq("Listing")
    else
      call_api(:post, "/api/v1/bookings", user, params: booking_params(@book_lead), status: :forbidden)
      call_api(:get, "/api/v1/bookings", user, status: :forbidden)
      call_api(:get, "/api/v1/bookings/#{@booking_id}", user, status: :forbidden)
    end
  end

  def import_listing(user)
    mobile = user.manager? ? "9811100091" : "9811100092"
    call_api(:post, "/api/v1/leads/import", user, params: { file: csv_upload(mobile) }, multipart: true, status: :ok)
    expect(response.parsed_body["created_count"]).to eq(1)
    lead_id = response.parsed_body.dig("results", 0, "lead_id")
    call_api(:get, "/api/v1/leads/#{lead_id}", user, status: :ok)
  end

  def booking_params(lead)
    {
      lead_id: lead.id, property_id: @bare.id, booked_on: "2026-10-20",
      agreement_value: 11_300_000, commission_percent: 2
    }
  end

  def expect_listing_match
    row = response.parsed_body["matches"].find { |item| item["id"] == @listing.id }
    expect(row).to be_present
    expect(row["marketplace"]).to be(true)
    return if row["distance_m"].nil?

    expect(row["distance_rounded"]).to be(true)
    expect(row["distance_m"] % 500).to eq(0)
  end

  def member(firm, role, name, mobile)
    create(:user, firm:, role:, name:, mobile:, email: "#{name.parameterize}@example.com")
  end

  def place_lead(firm, agent, name:, mobile:, email:, budget:, notes:, label:, address:, lat:, lng:)
    create(:lead, firm:, assigned_user: agent, lead_status: @status, property_type: @ready,
      name:, mobile:, email:, budget_max: budget, notes:, transaction_type: "sale",
      near_label: label, near_address: address, near_lat: lat, near_lng: lng).tap do |lead|
      lead.typologies << @typology
      lead.localities << @locality
    end
  end

  def buyer_lead(name, mobile, email, budget, label, address, notes, lat, lng)
    lead = place_lead(@firm_b, @agent_b, name:, mobile:, email:, budget:, notes:, label:, address:, lat:, lng:)
    lead.reload
    @b_secret.concat([
      name, notes, label, address, email, mobile, budget.to_s, lead.id,
      pin_fragment(lead.near_lat), pin_fragment(lead.near_lng)
    ])
    lead
  end

  def as_viewer(forbidden, own)
    @forbidden = forbidden.map(&:to_s).uniq
    @own = own.map(&:to_s).uniq
    yield
  end

  def sign_in(user)
    @tokens[user.id] ||= begin
      post "/api/v1/auth/otp", params: { mobile: user.mobile }, as: :json
      request_id = response.parsed_body["request_id"]
      post "/api/v1/auth/verify", params: { request_id:, code: deliverer.last.code }, as: :json
      { "Authorization" => "Bearer #{response.parsed_body['access_token']}" }
    end
  end

  def call_api(method, path, user, params: nil, status: nil, multipart: false)
    # dup: a JSON GET with params stores X-Http-Method-Override on the header
    # hash, and a later POST would be turned into that GET.
    options = { headers: sign_in(user).dup }
    options[:params] = params unless params.nil?
    options[:as] = :json unless multipart
    public_send(method, path, **options)
    expect(response).to have_http_status(status) if status
    scan("#{method.to_s.upcase} #{path}", response)
  end

  def scan(where, response)
    text = response.body.to_s
    @forbidden.each do |marker|
      next if marker.blank?

      expect(text).not_to include(marker), "#{marker} appeared in #{where}"
    end
    left = text.dup
    @own.sort_by { |marker| -marker.length }.each do |marker|
      next if marker.blank?

      left.gsub!(marker, "")
    end
    expect(left).not_to match(/zqx/i), "a ZQX string remained in #{where}"
    assert_distances(text, where)
  end

  def assert_distances(body, where)
    data = JSON.parse(body)
    each_hash(data) do |hash|
      next unless cross_firm_distance?(hash)

      # marketplace_matches documents distance_m without distance_rounded.
      # Match rows carry the flag. Either way the metres are a multiple of 500.
      if hash.key?("distance_rounded") || hash.key?("kind")
        expect(hash["distance_rounded"]).to be(true), "distance in #{where} was not rounded"
      end
      expect(hash["distance_m"] % 500).to eq(0), "distance in #{where} was #{hash['distance_m']}"
      @distances << hash["distance_m"]
    end
  rescue JSON::ParserError
    nil
  end

  def cross_firm_distance?(hash)
    return false unless hash.is_a?(Hash) && hash.key?("distance_m") && !hash["distance_m"].nil?

    hash["marketplace"] == true || hash["own"] == false
  end

  def each_hash(node, &block)
    case node
    when Hash
      yield node
      node.each_value { |value| each_hash(value, &block) }
    when Array
      node.each { |value| each_hash(value, &block) }
    end
  end

  def assert_distinct_pins(values)
    fragments = values.map { |value| pin_fragment(value) }
    fulls = values.map { |value| value.to_d.to_s("F") }
    fragments.each do |fragment|
      hits = fulls.count { |full| full.include?(fragment) }
      expect(hits).to eq(1), "#{fragment} is shared by more than one fixture pin"
    end
  end

  def pin_fragment(value)
    whole, frac = value.to_d.to_s("F").split(".", 2)
    "#{whole}.#{frac.to_s[0, 3]}"
  end

  def csv_upload(mobile)
    values = {
      name: "Sheet Buyer", mobile:, transaction_type: "sale", property_type: "Ready possession",
      budget: "12000000", configurations: "2 BHK", location: "Worli, Mumbai", property_codes: @listing.code
    }
    csv = CSV.generate do |sheet|
      sheet << Leads::Import::HEADERS.map(&:last)
      sheet << Leads::Import::HEADERS.map { |key, _name| values[key] }
    end
    file = Tempfile.new([ "leads", ".csv" ])
    file.write(csv)
    file.rewind
    Rack::Test::UploadedFile.new(file.path, "text/csv", original_filename: "leads.csv")
  end
end
