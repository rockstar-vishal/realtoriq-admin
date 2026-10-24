# frozen_string_literal: true

require "rails_helper"
require "rake"

RSpec.describe "leads:backfill_booked_at" do
  before(:all) do
    Rails.application.load_tasks unless Rake::Task.task_defined?("leads:backfill_booked_at")
  end

  def run_task
    Rake::Task["leads:backfill_booked_at"].tap(&:reenable).invoke
  end

  def with_dry_run(value)
    previous = ENV["DRY_RUN"]
    if value.nil?
      ENV.delete("DRY_RUN")
    else
      ENV["DRY_RUN"] = value
    end
    yield
  ensure
    if previous.nil?
      ENV.delete("DRY_RUN")
    else
      ENV["DRY_RUN"] = previous
    end
  end

  it "sets booked_at from the earliest live booking, else the latest booked status change, else leaves it" do
    firm = create(:firm)
    booked = create(:lead_status, :booked)
    hot = create(:lead_status, :hot)
    from_booking = create(:lead, firm:, lead_status: booked, booked_at: nil)
    from_change = create(:lead, firm:, lead_status: booked, booked_at: nil)
    left = create(:lead, firm:, lead_status: booked, booked_at: nil)
    already = Time.zone.local(2026, 3, 1, 10, 0)
    kept = create(:lead, firm:, lead_status: booked, booked_at: already)

    create(:booking, :cancelled, firm:, lead: from_booking, booked_on: Date.new(2026, 1, 1))
    create(:booking, firm:, lead: from_booking, booked_on: Date.new(2026, 8, 1))
    create(:booking, firm:, lead: from_booking, booked_on: Date.new(2026, 6, 2))
    create(:booking, :cancelled, firm:, lead: left, booked_on: Date.new(2026, 2, 1))

    earlier = Time.zone.local(2026, 5, 1, 9, 0)
    latest = Time.zone.local(2026, 7, 1, 15, 30)
    after = Time.zone.local(2026, 8, 1, 11, 0)
    LeadStatusChange.create!(firm:, lead: from_change, from_status: hot, to_status: booked, changed_at: earlier)
    LeadStatusChange.create!(firm:, lead: from_change, from_status: hot, to_status: booked, changed_at: latest)
    LeadStatusChange.create!(firm:, lead: from_change, from_status: booked, to_status: hot, changed_at: after)
    LeadStatusChange.create!(firm:, lead: left, from_status: hot, to_status: hot, changed_at: after)

    with_dry_run(nil) do
      expect { run_task }.to output(<<~OUT).to_stdout
        booking 1
        status_change 1
        unchanged 1
        would set 2
      OUT
    end

    expect(from_booking.reload.booked_at).to be_nil
    expect(from_change.reload.booked_at).to be_nil
    expect(left.reload.booked_at).to be_nil

    with_dry_run("0") do
      expect { run_task }.to output(<<~OUT).to_stdout
        booking 1
        status_change 1
        unchanged 1
        set 2
      OUT
    end

    expect(from_booking.reload.booked_at).to eq(Date.new(2026, 6, 2).in_time_zone(Lead::NCD_ZONE).beginning_of_day)
    expect(from_change.reload.booked_at).to eq(latest)
    expect(left.reload.booked_at).to be_nil
    expect(kept.reload.booked_at).to eq(already)
  end
end
