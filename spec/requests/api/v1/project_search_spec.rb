# frozen_string_literal: true

require "rails_helper"

RSpec.describe "API v1 project search" do
  let(:plan) { create(:plan) }
  let(:firm) { create(:firm, status: :active) }
  let!(:subscription) { create(:subscription, firm:, plan:) }
  let!(:user) { create(:user, :super_admin, firm:) }
  let!(:agent) { create(:user, firm:, role: :agent) }

  let(:builder) { create(:builder, firm: nil, name: "Lodha Group") }
  let(:city) { create(:city, name: "Thane") }
  let(:locality) { create(:locality, city:, name: "Kolshet") }

  def auth(as: user)
    post "/api/v1/auth/otp", params: { mobile: as.mobile }, as: :json
    request_id = response.parsed_body["request_id"]
    post "/api/v1/auth/verify",
      params: { request_id:, code: Notifications::Deliverer.current.last.code }, as: :json
    { "Authorization" => "Bearer #{response.parsed_body['access_token']}" }
  end

  def project(name, **attrs)
    create(:project, firm:, name:, builder:, city:, locality:, **attrs)
  end

  def search(q, headers: auth)
    get "/api/v1/projects/search", params: { q: }, headers: headers
    response.parsed_body
  end

  def hit_names(q) = search(q).fetch("projects").map { |p| p["name"] }

  describe "the three-character minimum" do
    it "refuses fewer than three characters, saying how many it needs" do
      body = search("au")

      expect(response).to have_http_status(:unprocessable_content)
      expect(body.dig("error", "code")).to eq("query_too_short")
      expect(body.dig("error", "details")).to eq("min_length" => 3, "length" => 2)
    end

    it "counts characters after trimming, so padding does not sneak past it" do
      search("  a  ")

      expect(response.parsed_body.dig("error", "details", "length")).to eq(1)
    end

    it "treats a missing query as too short" do
      get "/api/v1/projects/search", headers: auth

      expect(response.parsed_body.dig("error", "code")).to eq("query_too_short")
    end

    it "treats a query sent as an array as too short, rather than searching for its string form" do
      get "/api/v1/projects/search?q[]=aurum", headers: auth

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body.dig("error", "code")).to eq("query_too_short")
    end

    it "searches at exactly three" do
      project("Aurum Vista")

      expect(hit_names("aur")).to eq([ "Aurum Vista" ])
    end

    it "counts characters, not bytes, for names that aren't in English" do
      project("गोदरेज हिल्स") # Godrej Hills — three Devanagari characters are 9 bytes

      get "/api/v1/projects/search", params: { q: "गोद" }, headers: auth

      expect(response).to have_http_status(:ok)
    end
  end

  describe "typo tolerance on the name" do
    # The typos the threshold was measured against. See ProjectSearch.
    before do
      project("Aurum Vista")
      project("Lodha Amara Tower 7")
      project("Sunteck Skypark")
      project("Hiranandani Estate")
    end

    {
      "aurm" => "Aurum Vista",         # dropped letter
      "lodah" => "Lodha Amara Tower 7", # swapped letters
      "skypak" => "Sunteck Skypark",
      "hiranandni" => "Hiranandani Estate"
    }.each do |typo, expected|
      it "finds #{expected} from #{typo.inspect}" do
        expect(hit_names(typo)).to include(expected)
      end
    end

    it "returns nothing for text that resembles no project" do
      expect(hit_names("xyzq")).to eq([])
    end
  end

  describe "the RERA number" do
    before { project("Aurum Vista", rera_number: "P51700054321") }

    it "finds a project by a fragment of its registration" do
      expect(hit_names("0054321")).to eq([ "Aurum Vista" ])
    end

    it "ignores case" do
      expect(hit_names("p517")).to eq([ "Aurum Vista" ])
    end

    # A near-miss registration number is a different project, so it must not
    # match the way a misspelt name does.
    it "does not fuzzy-match a registration that is merely similar" do
      expect(hit_names("P51700054329")).to eq([])
    end
  end

  describe "ranking" do
    it "orders exact, then prefix, then substring" do
      project("Aurum Vista")    # substring of "vista"
      project("Vista Grande")   # prefix
      project("Vista")          # exact

      expect(hit_names("vista")).to eq([ "Vista", "Vista Grande", "Aurum Vista" ])
    end

    it "puts an exact RERA match first" do
      project("P5170 Towers") # name merely starts with the query
      project("Zenith", rera_number: "P5170")

      expect(hit_names("P5170").first).to eq("Zenith")
    end
  end

  describe "builder and location" do
    it "finds a project by its builder, city or locality" do
      project("Aurum Vista")

      expect(hit_names("Lodha")).to eq([ "Aurum Vista" ])
      expect(hit_names("Thane")).to eq([ "Aurum Vista" ])
      expect(hit_names("Kolshet")).to eq([ "Aurum Vista" ])
    end

    it "does not match the street address" do
      project("Aurum Vista", address: "Palm Beach Road")

      expect(hit_names("Palm Beach")).to eq([])
    end

    it "searches archived projects when asked, and leaves them out otherwise" do
      project("Aurum Vista")
      project("Aurum Archive", status: "archived")

      expect(hit_names("aurum")).to eq([ "Aurum Vista" ])

      get "/api/v1/projects/search", params: { q: "aurum", status: "archived" }, headers: auth

      expect(response.parsed_body["projects"].map { |p| p["name"] }).to eq([ "Aurum Archive" ])
    end
  end

  describe "what is searched" do
    it "only returns this firm's projects" do
      other = create(:firm)
      create(:project, firm: other, name: "Aurum Vista Elsewhere")
      project("Aurum Vista")

      expect(hit_names("aurum")).to eq([ "Aurum Vista" ])
    end

    it "leaves archived projects out, as GET /projects does" do
      project("Aurum Vista")
      project("Aurum Archive", status: "archived")

      expect(hit_names("aurum")).to eq([ "Aurum Vista" ])
    end

    it "treats SQL wildcards in the query as literal text" do
      project("Aurum Vista")
      project("100% Ready")

      expect(hit_names("00% R")).to eq([ "100% Ready" ])
      expect(hit_names("00_ R")).to eq([])
    end
  end

  describe "the limit" do
    it "caps at ten and says there is more" do
      12.times { |i| project("Aurum Vista #{i + 1}") }

      body = search("aurum")

      expect(body["projects"].size).to eq(10)
      expect(body.dig("meta", "more")).to be(true)
    end

    it "says there is no more when everything fits" do
      3.times { |i| project("Aurum Vista #{i + 1}") }

      expect(search("aurum").dig("meta", "more")).to be(false)
    end
  end

  describe "the payload" do
    it "carries only what a result row shows" do
      project("Aurum Vista", rera_number: "P51700054321")

      hit = search("aurum")["projects"].first

      expect(hit.keys).to match_array(%w[id name rera_number source builder locality locality_id city city_id])
      expect(hit).to include(
        "name" => "Aurum Vista", "rera_number" => "P51700054321", "source" => "own",
        "builder" => { "id" => builder.id, "name" => "Lodha Group" },
        "locality" => "Kolshet", "city" => "Thane",
        "locality_id" => locality.id, "city_id" => city.id
      )
    end

    it "echoes the query it actually used, trimmed" do
      project("Aurum Vista")

      expect(search("  aurum  ").dig("meta", "query")).to eq("aurum")
    end
  end

  describe "who can search" do
    it "lets an agent search, as inventory is visible to every role" do
      project("Aurum Vista")

      expect(search("aurum", headers: auth(as: agent))["projects"].size).to eq(1)
    end

    it "requires sign-in" do
      get "/api/v1/projects/search", params: { q: "aurum" }

      expect(response).to have_http_status(:unauthorized)
    end
  end

  it "is not mistaken for a project id by the show route" do
    get "/api/v1/projects/search", params: { q: "aurum" }, headers: auth

    expect(response.parsed_body).not_to have_key("project")
  end

  # ---------------------------------------------------------------------------
  # Found by review. Each of these was reproduced before it was fixed.
  # ---------------------------------------------------------------------------

  describe "fuzzy matching is a fallback, not a mixer" do
    # Trigram similarity cannot tell a typo from a name that merely starts the
    # same way, so mixing both into one ranked list padded short queries with
    # unrelated projects and set a false "keep typing".
    #
    # The shared builder is "Lodha Group", and "lod" is now a literal builder
    # match — which would return every project in this example. A builder name
    # that does not contain the query keeps the example about project names.
    let(:builder) { create(:builder, firm: nil, name: "Meridian Group") }

    before do
      project("Lodha Amara")
      project("Lotus Park")
      project("Loft Residency")
      project("Lokhandwala Complex")
      project("Godrej Reserve")
      project("Godavari Heights")
    end

    it "returns only literal matches when the text appears as typed" do
      expect(hit_names("lod")).to eq([ "Lodha Amara" ])
      expect(hit_names("lodh")).to eq([ "Lodha Amara" ])
      expect(hit_names("godr")).to eq([ "Godrej Reserve" ])
      expect(search("lod").dig("meta", "fuzzy")).to be(false)
    end

    it "does not call ten unrelated names 'more'" do
      8.times { |i| project("Lotus Residency #{i + 1}") }

      body = search("lod")

      expect(body["projects"].map { |p| p["name"] }).to eq([ "Lodha Amara" ])
      expect(body.dig("meta", "more")).to be(false)
    end

    it "falls back to close spellings only when nothing matches as typed, and says so" do
      project("Aurum Vista")
      project("Austin Heights")
      project("Autumn Leaf")

      body = search("aurm")

      # Austin and Autumn share only "au" with the typo and score 0.40.
      expect(body["projects"].map { |p| p["name"] }).to eq([ "Aurum Vista" ])
      expect(body.dig("meta", "fuzzy")).to be(true)
    end

    it "offers a close spelling ranked by how close it is" do
      body = search("godrj")

      expect(body["projects"].map { |p| p["name"] }.first).to eq("Godrej Reserve")
      expect(body.dig("meta", "fuzzy")).to be(true)
    end

    it "does not attempt fuzzy matching below four letters, where it is all noise" do
      project("Aurum Vista")
      project("Austin Heights")

      body = search("auq")

      expect(body["projects"]).to eq([])
      expect(body.dig("meta", "fuzzy")).to be(false)
    end
  end

  describe "the minimum counts letters and numbers" do
    # "___" is three characters but no trigrams, so it read every row the firm
    # owns instead of using the index.
    %w[___ !!! %%% ...].each do |junk|
      it "refuses #{junk.inspect}" do
        search(junk)

        expect(response).to have_http_status(:unprocessable_content)
        expect(response.parsed_body.dig("error", "details", "length")).to eq(0)
      end
    end
  end

  describe "pasted text" do
    let(:nbsp) { 0xA0.chr(Encoding::UTF_8) }
    let(:zero_width) { 0x200B.chr(Encoding::UTF_8) }

    before { project("Aurum Vista", rera_number: "P51700054321") }

    # String#strip leaves a non-breaking space in place, and a RERA number
    # copied from a web page usually ends in one.
    it "finds a RERA number that arrived with a trailing non-breaking space" do
      expect(hit_names("P51700054321#{nbsp}")).to eq([ "Aurum Vista" ])
    end

    it "finds one that arrived with a zero-width space in front" do
      expect(hit_names("#{zero_width}P51700054321")).to eq([ "Aurum Vista" ])
    end

    it "does not let invisible padding carry two letters past the minimum" do
      search("au#{nbsp}#{zero_width}")

      expect(response).to have_http_status(:unprocessable_content)
    end

    it "collapses repeated spaces" do
      expect(hit_names("aurum   vista")).to eq([ "Aurum Vista" ])
    end
  end

  describe "a full-length name" do
    # The query cap used to be 100 while names may be 160, so a pasted full name
    # was cut short and could never be an exact match.
    it "matches a name at the length limit exactly" do
      long = "Aurum " + ("Vista " * 30)
      long = long.first(Project::NAME_MAX_LENGTH).strip
      project(long)
      project(long.first(100))

      expect(hit_names(long).first).to eq(long)
    end
  end

  describe "a NUL byte" do
    let(:nul) { 0.chr }

    # Postgres text cannot hold one, and the pg adapter raised the moment it was
    # bound — a 500 HTML page. Removed in BaseController for every endpoint.
    it "is removed before searching, not turned into a 500" do
      project("Aurum Vista")

      expect(hit_names("aur#{nul}um")).to eq([ "Aurum Vista" ])
      expect(response).to have_http_status(:ok)
    end
  end
end
