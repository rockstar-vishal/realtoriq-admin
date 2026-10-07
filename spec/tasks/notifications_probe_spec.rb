# frozen_string_literal: true

require "rails_helper"
require "rake"

RSpec.describe "notifications probe" do
  before(:all) do
    Rails.application.load_tasks unless Rake::Task.task_defined?("notifications:probe")
  end

  def run_task
    Rake::Task["notifications:probe"].tap(&:reenable).invoke
  end

  it "refuses to send outside production" do
    expect { run_task }.to output(/only runs in production/).to_stderr.and raise_error(SystemExit)
  end
end
