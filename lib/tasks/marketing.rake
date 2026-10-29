# frozen_string_literal: true

namespace :marketing do
  desc "Check marketing fonts, PDF thumbnails and gems, and write sample creatives"
  task doctor: :environment do
    lines, failed = Marketing::Doctor.call
    lines.each { |line| puts line }
    exit 1 if failed
  end
end
