# frozen_string_literal: true

require "net/http"
require "openssl"

module Realtoriq
  # Downloads one LaunchIQ file. The URL in the payload is an Active Storage
  # redirect; the S3 URL behind it is short-lived, so this runs in the asset
  # job, not in the webhook.
  class RemoteFile
    class Error < StandardError; end

    MAX_BYTES = 20.megabytes
    MAX_REDIRECTS = 3
    IMAGE_TYPES = %w[image/jpeg image/png image/webp].freeze
    BROCHURE_TYPES = %w[application/pdf].freeze

    def self.fetch(url, content_types:)
      new(url).fetch(content_types:)
    end

    def self.allowed_host?(uri)
      host = uri.host.to_s.downcase
      return false if host.blank?

      origin_hosts.include?(host) || s3_host?(host)
    end

    def self.origin_hosts
      [ Credentials.turbo_public_origin, Credentials.turbo_api_origin ].filter_map do |raw|
        next if raw.blank?

        URI.parse(raw).host&.downcase
      end.uniq
    rescue URI::InvalidURIError
      []
    end

    def self.s3_host?(host)
      host.match?(/\.s3[.-][a-z0-9.-]*amazonaws\.com\z/) ||
        host.match?(/\As3[.-][a-z0-9.-]*amazonaws\.com\z/)
    end

    def initialize(url)
      @url = url.to_s
    end

    def fetch(content_types:)
      uri = URI.parse(@url)
      raise Error, "file URL must be https" unless uri.is_a?(URI::HTTPS)
      raise Error, "file host is not allowed" unless self.class.allowed_host?(uri)

      redirects = 0
      loop do
        response, body = read(uri)
        if redirect?(response)
          redirects += 1
          raise Error, "too many redirects" if redirects > MAX_REDIRECTS

          location = response["location"]
          raise Error, "redirect had no location" if location.blank?

          uri = URI.join(uri, location)
          raise Error, "redirect left https" unless uri.is_a?(URI::HTTPS)
          raise Error, "file host is not allowed" unless self.class.allowed_host?(uri)

          next
        end

        raise Error, "file download failed (HTTP #{response.code})" unless success?(response)

        type = response["content-type"].to_s.split(";").first.to_s.strip.downcase
        unless content_types.include?(type)
          body.close! if body.respond_to?(:close!)
          raise Error, "file type is not allowed"
        end

        return body
      end
    rescue Error
      raise
    rescue StandardError => e
      raise Error, "file download failed (#{e.class})"
    end

    private

    def read(uri)
      Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 5, read_timeout: 15) do |http|
        http.request(Net::HTTP::Get.new(uri)) do |response|
          return [ response, nil ] if redirect?(response) || !success?(response)

          file = Tempfile.new("realtoriq-remote", binmode: true)
          begin
            response.read_body do |chunk|
              file.write(chunk)
              raise Error, "file is too large" if file.size > MAX_BYTES
            end
            file.rewind
            return [ response, file ]
          rescue StandardError
            file.close!
            raise
          end
        end
      end
    end

    def success?(response)
      response.code.to_s.start_with?("2")
    end

    def redirect?(response)
      response.code.to_s.start_with?("3")
    end
  end
end
