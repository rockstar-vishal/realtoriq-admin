# frozen_string_literal: true

namespace :categories do
  desc "Confirm configurations, merge old names, and add commercial and land inactive. DRY_RUN=1 writes nothing."
  task backfill: :environment do
    Inventory::CategoriesBackfill.call(dry_run: ENV["DRY_RUN"] == "1")
  end

  desc "Show the commercial and plot configurations in broker dropdowns"
  task activate: :environment do
    Inventory::CategoriesActivate.call
  end
end
