# frozen_string_literal: true

require "rails_helper"
require "rake"

RSpec.describe "firms:pin" do
  before(:all) do
    Rails.application.load_tasks unless Rake::Task.task_defined?("firms:pin")
  end

  def run_task
    Rake::Task["firms:pin"].tap(&:reenable).invoke
  end

  def mumbai_with_localities
    city = create(:city, name: "Mumbai", state: "Maharashtra")
    {
      city:,
      andheri: create(:locality, city:, name: "Andheri West"),
      powai: create(:locality, city:, name: "Powai"),
      kharghar: create(:locality, city:, name: "Kharghar")
    }
  end

  it "pins a firm with no locality and leaves a pin that is already set" do
    places = mumbai_with_localities
    aarav = create(:firm, name: "Aarav Realty", city: nil, locality: nil)
    kapoor = create(:firm, name: "Kapoor Estates", city: places[:city], locality: places[:andheri])

    expect { run_task }.to output(a_string_including("Pin Aarav Realty: Mumbai / Andheri West")).to_stdout

    expect(aarav.reload.city).to eq(places[:city])
    expect(aarav.locality).to eq(places[:andheri])
    expect(kapoor.reload.locality).to eq(places[:andheri])
  end

  it "changes nothing when a firm with no pin is not in the map" do
    mumbai_with_localities
    aarav = create(:firm, name: "Aarav Realty", city: nil, locality: nil)
    create(:firm, name: "Other Realty", city: nil, locality: nil)

    expect { run_task }.to output(/No pin mapped for Other Realty/).to_stderr.and raise_error(SystemExit)

    expect(aarav.reload.locality).to be_nil
  end

  it "changes nothing when Mumbai is missing" do
    aarav = create(:firm, name: "Aarav Realty", city: nil, locality: nil)

    expect { run_task }.to output(/Mumbai is not in the locality masters/).to_stderr.and raise_error(SystemExit)

    expect(aarav.reload.locality).to be_nil
  end
end
