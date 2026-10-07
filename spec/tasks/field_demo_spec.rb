# frozen_string_literal: true

require "rails_helper"
require "rake"

RSpec.describe "field demo task" do
  before(:all) do
    Rails.application.load_tasks unless Rake::Task.task_defined?("field_demo:enable")
  end

  def run_task
    Rake::Task["field_demo:enable"].tap(&:reenable).invoke
  end

  it "flags Aarav Realty and Deshmukh Properties and leaves everyone else" do
    aarav = create(:firm, name: "Aarav Realty")
    deshmukh = create(:firm, name: "Deshmukh Properties")
    kapoor = create(:firm, name: "Kapoor Estates")

    expect { run_task }.to output(a_string_including("Field demo sign-in ready")).to_stdout

    expect(aarav.reload).to be_field_demo
    expect(deshmukh.reload).to be_field_demo
    expect(kapoor.reload).not_to be_field_demo
  end

  it "changes nothing when one of the firms is missing" do
    aarav = create(:firm, name: "Aarav Realty")

    expect { run_task }.to output(/Missing Deshmukh Properties/).to_stderr.and raise_error(SystemExit)

    expect(aarav.reload).not_to be_field_demo
  end
end
