# frozen_string_literal: true

# What a file is for, and therefore what it's allowed to be.
#
# The limits come from the design: booking documents are capped at 2 MB and
# brochures at 5 MB on the screens themselves. They are enforced when the upload
# ticket is issued, because a client-side check is a suggestion — the browser
# talks straight to storage after that, and this is the last point we control.
class UploadPurpose
  PURPOSES = {
    "booking_document" => {
      max_bytes: 2.megabytes,
      content_types: %w[application/pdf image/jpeg image/png]
    },
    "project_brochure" => {
      max_bytes: 5.megabytes,
      content_types: %w[application/pdf]
    },
    "project_photo" => {
      max_bytes: 5.megabytes,
      content_types: %w[image/jpeg image/png image/webp]
    },
    "property_photo" => {
      max_bytes: 5.megabytes,
      content_types: %w[image/jpeg image/png image/webp]
    },
    "collection_proof" => {
      max_bytes: 2.megabytes,
      content_types: %w[application/pdf image/jpeg image/png]
    },
    "firm_logo" => {
      max_bytes: 1.megabyte,
      content_types: %w[image/png image/jpeg image/svg+xml image/webp]
    }
  }.freeze

  Rejection = Struct.new(:code, :message)

  attr_reader :name

  def initialize(name)
    @name = name.to_s
    @rules = PURPOSES[@name]
  end

  def known? = @rules.present?

  def max_bytes = @rules[:max_bytes]

  def content_types = @rules[:content_types]

  # Returns nil when acceptable, or a Rejection explaining what to fix.
  def reject(byte_size:, content_type:)
    unless known?
      return Rejection.new("unknown_purpose",
                           "Unknown purpose. One of: #{PURPOSES.keys.join(', ')}")
    end

    if byte_size.to_i <= 0
      return Rejection.new("invalid_size", "byte_size is required")
    end

    if byte_size.to_i > max_bytes
      return Rejection.new(
        "file_too_large",
        "#{name.humanize} files must be #{max_bytes / 1.megabyte} MB or smaller"
      )
    end

    unless content_types.include?(content_type.to_s)
      return Rejection.new(
        "unsupported_type",
        "#{name.humanize} accepts #{content_types.join(', ')}"
      )
    end

    nil
  end

  def self.catalogue
    PURPOSES.map do |name, rules|
      { purpose: name, max_bytes: rules[:max_bytes], content_types: rules[:content_types] }
    end
  end
end
