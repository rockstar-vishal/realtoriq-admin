# frozen_string_literal: true

require "rails_helper"

RSpec.describe Marketing::VideoLink do
  def accepted(url, provider, youtube_id: nil)
    link = described_class.parse(url)
    expect(link).to have_attributes(url:, provider:, youtube_id:)
  end

  it "accepts YouTube, Instagram, Facebook and Google Drive links" do
    id = "dQw4w9WgXcQ"
    accepted("https://www.youtube.com/watch?v=#{id}", "youtube", youtube_id: id)
    accepted("https://m.youtube.com/watch?v=#{id}&t=12s", "youtube", youtube_id: id)
    accepted("https://youtu.be/#{id}", "youtube", youtube_id: id)
    accepted("https://www.youtube.com/shorts/#{id}", "youtube", youtube_id: id)
    accepted("https://www.youtube.com/embed/#{id}", "youtube", youtube_id: id)
    accepted("https://www.youtube.com/live/#{id}", "youtube", youtube_id: id)

    accepted("https://www.instagram.com/reel/CxAb12/", "instagram")
    accepted("https://m.instagram.com/reels/CxAb12", "instagram")
    accepted("https://instagram.com/p/CxAb12", "instagram")
    accepted("https://www.instagram.com/tv/CxAb12", "instagram")

    accepted("https://www.facebook.com/watch/?v=123456789", "facebook")
    accepted("https://m.facebook.com/reel/123456789", "facebook")
    accepted("https://www.facebook.com/page/videos/123456789", "facebook")
    accepted("https://www.facebook.com/share/v/AbCdEfGh", "facebook")
    accepted("https://www.facebook.com/video.php?v=123456789", "facebook")
    accepted("https://fb.watch/AbCdEf/", "facebook")

    accepted("https://drive.google.com/file/d/1AbCdEfGhIjKlMnOp/view", "google_drive")
    accepted("https://www.drive.google.com/open?id=1AbCdEfGhIjKlMnOp", "google_drive")
  end

  it "matches the shared video link table" do
    [
      [ "https://www.youtube.com/watch?v=dQw4w9WgXcQ", "youtube" ],
      [ "https://youtu.be/dQw4w9WgXcQ?si=abc", "youtube" ],
      [ "https://youtube.com/shorts/dQw4w9WgXcQ?feature=share", "youtube" ],
      [ "https://m.youtube.com/watch?v=dQw4w9WgXcQ&t=10", "youtube" ],
      [ "https://www.youtube.com/live/dQw4w9WgXcQ", "youtube" ],
      [ "https://www.youtube.com./watch?v=dQw4w9WgXcQ", "youtube" ],
      [ "https://www.instagram.com/reel/C9abcDEF123/?igsh=xyz", "instagram" ],
      [ "https://www.instagram.com/kgen.realty/reel/C9abcDEF123/", "instagram" ],
      [ "https://www.instagram.com/p/C9abcDEF123/", "instagram" ],
      [ "https://www.instagram.com/reels/C9abcDEF123/", "instagram" ],
      [ "https://www.facebook.com/reel/1234567890", "facebook" ],
      [ "https://www.facebook.com/kgenpage/reels/1234567890/", "facebook" ],
      [ "https://www.facebook.com/kgenpage/videos/1234567890/", "facebook" ],
      [ "https://www.facebook.com/kgenpage/video/1234567890/", "facebook" ],
      [ "https://www.facebook.com/kgenpage/videos/project-film/1234567890/", "facebook" ],
      [ "https://www.facebook.com/watch/?v=1234567890", "facebook" ],
      [ "https://www.facebook.com/share/v/1AbCdEf/", "facebook" ],
      [ "https://www.facebook.com/share/r/1AbCdEf/", "facebook" ],
      [ "https://fb.watch/abcDEF123/", "facebook" ],
      [ "https://drive.google.com/file/d/1AbCdEfGhIjKlMnOp/view?usp=sharing", "google_drive" ],
      [ "https://drive.google.com/open?id=1AbCdEfGhIjKlMnOp", "google_drive" ],
      [ "https://user@www.youtube.com/watch?v=dQw4w9WgXcQ", "rejected" ],
      [ "http://youtu.be/dQw4w9WgXcQ", "rejected" ]
    ].each do |url, provider|
      if provider == "rejected"
        expect(described_class.parse(url)).to be_nil
      else
        accepted(url, provider, youtube_id: (provider == "youtube" ? "dQw4w9WgXcQ" : nil))
      end
    end
  end

  it "rejects a link that is not one of those pages" do
    [
      "http://youtu.be/dQw4w9WgXcQ",
      "https://evil.example/watch?v=dQw4w9WgXcQ",
      "https://youtube.com/channel/UCdQw4w9WgXcQ",
      "https://instagram.com/stories/name",
      "https://facebook.com/zuck",
      "https://drive.google.com/drive/folders/1AbCdEfGhIjKlMnOp",
      "https://user:pass@youtube.com/watch?v=dQw4w9WgXcQ",
      "",
      nil
    ].each do |url|
      expect(described_class.parse(url)).to be_nil
    end
  end

  it "builds a YouTube thumbnail from the id" do
    expect(described_class.thumb_url("dQw4w9WgXcQ")).to eq("https://i.ytimg.com/vi/dQw4w9WgXcQ/hqdefault.jpg")
    expect(described_class.thumb_url(nil)).to be_nil
  end
end
