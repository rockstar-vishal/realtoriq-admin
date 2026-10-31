# frozen_string_literal: true

module Marketing
  # A creative video is a link, not a file. The host decides the provider.
  # LaunchIQ's own provider value is only a hint and is not trusted here.
  class VideoLink
    Result = Data.define(:url, :provider, :youtube_id, :drive_id) do
      def thumb_url
        return VideoLink.thumb_url(youtube_id) if youtube_id.present?
        return if drive_id.blank?

        "https://drive.google.com/thumbnail?id=#{drive_id}&sz=w640"
      end
    end
    YOUTUBE_ID = /\A[\w-]{11}\z/
    DRIVE_ID = /\A[\w-]{8,}\z/

    def self.parse(value)
      new(value).parse
    end

    def self.thumb_url(youtube_id)
      return if youtube_id.blank?

      "https://i.ytimg.com/vi/#{youtube_id}/hqdefault.jpg"
    end

    def initialize(value)
      @value = value.to_s.strip
    end

    def parse
      uri = parsed_uri
      return if uri.nil?

      found = match(uri, bare_host(uri.host))
      return if found.nil?

      Result.new(url: @value, provider: found[0], youtube_id: found[1], drive_id: found[2])
    end

    private

    def parsed_uri
      return if @value.blank? || @value.match?(/[\s<>]/)

      uri = URI.parse(@value)
      return unless uri.is_a?(URI::HTTPS)
      return if uri.host.blank? || uri.userinfo.present?

      uri
    rescue URI::InvalidURIError
      nil
    end

    def bare_host(host)
      name = host.downcase.delete_suffix(".")
      name = name.sub(/\A(?:www|m)\./, "") while name.match?(/\A(?:www|m)\./)
      name
    end

    def match(uri, host)
      case host
      when "youtube.com", "youtu.be" then youtube(uri, host)
      when "instagram.com" then instagram(uri)
      when "facebook.com", "fb.watch" then facebook(uri, host)
      when "drive.google.com" then drive(uri)
      end
    end

    def youtube(uri, host)
      id = host == "youtu.be" ? path_segment(uri.path) : youtube_page(uri)
      [ "youtube", id ] if id&.match?(YOUTUBE_ID)
    end

    def youtube_page(uri)
      case uri.path
      when %r{\A/watch/?\z} then query(uri, "v")
      when %r{\A/(?:shorts|embed|live)/([^/?#]+)} then Regexp.last_match(1)
      end
    end

    def instagram(uri)
      [ "instagram", nil ] if uri.path.match?(%r{\A/(?:[^/]+/)?(?:reel|reels|p|tv)/[^/?#]+})
    end

    def facebook(uri, host)
      return [ "facebook", nil ] if host == "fb.watch" && path_segment(uri.path).present?
      return unless facebook_video?(uri)

      [ "facebook", nil ]
    end

    def facebook_video?(uri)
      path = uri.path
      path.match?(%r{\A/watch(?:/|\z)}) ||
        path.match?(%r{\A/(?:[^/]+/)?(?:reel|reels)/[^/?#]+}) ||
        path.match?(%r{\A/share/[^/?#]+}) ||
        path.match?(%r{\A/(?:[^/]+/)?(?:videos|video)/[^/?#]+}) ||
        (path.match?(%r{\A/video\.php\z}) && query(uri, "v").present?)
    end

    def drive(uri)
      id = uri.path[%r{\A/file/d/([^/?#]+)}, 1]
      id = query(uri, "id") if id.blank? && uri.path.match?(%r{\A/open/?\z})
      [ "google_drive", nil, id ] if id&.match?(DRIVE_ID)
    end

    def path_segment(path)
      path.to_s.split("/").reject(&:empty?).first
    end

    def query(uri, key)
      URI.decode_www_form(uri.query.to_s).to_h[key]
    rescue ArgumentError
      nil
    end
  end
end
