# frozen_string_literal: true

namespace :matches do
  desc "Turn anchor matching on, rebuild neighbor pairs across cities, and rewrite digests quietly."
  task anchor_enable: :environment do
    Matches::EnableAnchors.call
  end

  desc "Turn anchor matching off, rebuild same-city neighbor pairs, and rewrite digests quietly."
  task anchor_disable: :environment do
    Matches::DisableAnchors.call
  end

  desc "Set the anchor radius in metres and rewrite digests quietly. METRES=3000"
  task anchor_radius: :environment do
    Matches::SetAnchorRadius.call(metres: ENV.fetch("METRES"))
  rescue ArgumentError, KeyError => error
    abort error.message
  end

  desc "Compare today's matches with anchor matching. Refuses to run in production. RADIUS=6000"
  task anchor_compare: :environment do
    abort "matches:anchor_compare cannot run in production" if Rails.env.production?

    radius = ENV["RADIUS"].presence || Inventory::Geo::ANCHOR_DEFAULT_M
    Matches::CompareAnchors.call(radius_m: radius)
  end
end
