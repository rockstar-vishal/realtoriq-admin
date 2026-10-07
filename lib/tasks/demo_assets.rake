# frozen_string_literal: true

namespace :demo_assets do
  desc "Upload Aarav Realty's demo photos to production S3. CONFIRM=1 DEMO_ASSETS_DIR=..."
  task attach_aarav: :environment do
    unless Rails.env.production? && ENV["CONFIRM"] == "1"
      abort("Run on the production server with CONFIRM=1.")
    end

    dir = Pathname(ENV.fetch("DEMO_ASSETS_DIR", Rails.root.join("../demo_assets/aarav-realty").to_s))
    abort("No demo photos at #{dir}") unless dir.join("palm-court-andheri-1.jpg").file?

    firm = Firm.find_by(name: "Aarav Realty")
    abort("Aarav Realty was not found.") if firm.nil?

    DemoAssets::AttachAarav.call(dir:, firm:)
  end
end
