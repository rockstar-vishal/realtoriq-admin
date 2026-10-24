# frozen_string_literal: true

namespace :leads do
  desc "Backfill booked_at on booked leads that have none. DRY_RUN=1 unless DRY_RUN=0"
  task backfill_booked_at: :environment do
    dry = ENV["DRY_RUN"] != "0"
    counts = { booking: 0, status_change: 0, unchanged: 0 }

    Lead.across_firms.where(booked_at: nil).joins(:lead_status).where(lead_statuses: { is_booked: true }).find_each do |lead|
      booking = lead.bookings.live.order(:booked_on, :created_at).first
      if booking
        stamp = booking.booked_on.in_time_zone(Lead::NCD_ZONE).beginning_of_day
        lead.update_columns(booked_at: stamp, updated_at: Time.current) unless dry
        counts[:booking] += 1
        next
      end

      change = lead.lead_status_changes.joins(:to_status).where(lead_statuses: { is_booked: true }).order(changed_at: :desc).first
      if change
        lead.update_columns(booked_at: change.changed_at, updated_at: Time.current) unless dry
        counts[:status_change] += 1
        next
      end

      counts[:unchanged] += 1
    end

    puts "booking #{counts[:booking]}"
    puts "status_change #{counts[:status_change]}"
    puts "unchanged #{counts[:unchanged]}"
    puts "#{dry ? "would set" : "set"} #{counts[:booking] + counts[:status_change]}"
  end
end
