# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Legal texts" do
  it "pins the published files and serves the latest version" do
    terms = Legal::Registry.current(:terms)
    privacy = Legal::Registry.current(:privacy)

    expect(terms.version).to eq("1.0")
    expect(privacy.version).to eq("1.0")
    expect(terms.sha256).to eq(Digest::SHA256.file(terms.path).hexdigest)
    expect(terms.text).not_to include("TODO")
    expect(terms.text).not_to include("[[")
    expect(privacy.text).to include("Grievance Officer")
  end

  it "escapes HTML and keeps the small markdown subset" do
    blocks = Legal::Markdown.parse("# Title\n\nHello\nthere\n\n- one\n  - nested\n")
    expect(blocks.map(&:type)).to eq([ :h1, :p, :li, :li ])
    expect(blocks[1].text).to eq("Hello there")
    expect(blocks[3].depth).to eq(1)

    document = Legal::Registry::Document.new(
      kind: "terms", version: "9.9", path: "", sha256: "abc",
      text: "See <script>alert(1)</script>\n\n**bold** and https://realtoriq.example/legal"
    )
    html = Legal::HtmlRenderer.new(document).render
    expect(html).to include("&lt;script&gt;")
    expect(html).not_to include("<script>")
    expect(html).to include("<strong>bold</strong>")
    expect(html).to include('href="https://realtoriq.example/legal"')
  end

  it "groups consecutive list items and nests a deeper item inside its parent" do
    document = Legal::Registry::Document.new(
      kind: "terms", version: "9.9", path: "", sha256: "abc",
      text: "- one\n  - nested\n- two\n"
    )
    html = Legal::HtmlRenderer.new(document).render

    expect(html).to include("<ul><li>one<ul><li>nested</li></ul></li><li>two</li></ul>")
    expect(html).not_to include("style=")
  end
end
