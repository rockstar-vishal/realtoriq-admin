# frozen_string_literal: true

require "rails_helper"

RSpec.describe Notifications::Target do
  def url(data) = described_class.url(data)

  it "is not clickable without a known page" do
    expect(url({})).to be_nil
    expect(url("page" => "https://evil.example")).to be_nil
    expect(url("lead_id" => "abc", "path" => "/leads/abc")).to be_nil
  end

  it "opens a lead show page and ignores list params when an item is set" do
    lead_id = "01a01644-191d-7000-abba-45a618136683"

    expect(url("page" => "leads", "item" => lead_id, "params" => { "filter" => "missed_followup" }))
      .to eq("/leads/#{lead_id}")
  end

  it "opens a filtered list from params" do
    expect(url("page" => "leads", "params" => { "filter" => "missed_followup" }))
      .to eq("/leads?filter=missed_followup")
  end

  it "opens a screen with no item and no params" do
    expect(url("page" => "settings")).to eq("/settings")
    expect(url("page" => "home")).to eq("/")
  end

  it "refuses an item or a param that could leave the app" do
    expect(url("page" => "leads", "item" => "../settings")).to be_nil
    expect(url("page" => "leads", "item" => "a/b")).to be_nil
    expect(url("page" => "leads", "params" => { "next" => "https://evil.example" }))
      .to eq("/leads?next=https%3A%2F%2Fevil.example")
    expect(url("page" => "leads", "params" => { "filter" => { "nested" => "x" } })).to be_nil
    expect(url("page" => "leads", "params" => { "bad key" => "x" })).to be_nil
  end
end
