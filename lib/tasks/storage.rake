# frozen_string_literal: true

namespace :storage do
  desc "Copy disk-service files onto S3 and point those blobs at the bucket. CONFIRM=1"
  task promote_to_s3: :environment do
    unless Rails.env.production? && ENV["CONFIRM"] == "1"
      abort("Run on the production server with CONFIRM=1.")
    end
    unless ActiveStorage::Blob.service.name.to_s == "amazon"
      abort("Production storage is not S3. Set STORAGE_SERVICE=amazon and AWS_BUCKET, then restart.")
    end

    source = ActiveStorage::Blob.services.fetch(:local)
    destination = ActiveStorage::Blob.services.fetch(:amazon)
    counts = Hash.new(0)

    ActiveStorage::Blob.where(service_name: "local").find_each do |blob|
      result = Storage::PromoteToS3.call(blob:, source:, destination:, destination_name: "amazon")
      counts[result] += 1
      puts "#{result} #{blob.filename}" unless result == :promoted
    end

    puts "promoted=#{counts[:promoted]} missing=#{counts[:missing]} checksum=#{counts[:checksum]}"
  end
end
