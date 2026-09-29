# frozen_string_literal: true

FactoryBot.define do
  factory :training do
    sequence(:title) { |n| "Real Estate Basics #{n}" }
    description { "Rules jaano. Buyer ko samjhao. Deal close karo." }
    intro_text { "Site visit perfect gaya. Family ko flat pasand aaya." }
    language { "hinglish" }
    status { "draft" }

    # Everything ops must supply before a training can be activated.
    trait :with_assets do
      after(:build) do |training|
        training.banner.attach(
          io: StringIO.new("banner-bytes"), filename: "banner.png", content_type: "image/png"
        )
        training.document.attach(
          io: StringIO.new("%PDF-1.4 guide"), filename: "guide.pdf", content_type: "application/pdf"
        )
        training.podcast.attach(
          io: StringIO.new("audio-bytes"), filename: "podcast.mp3", content_type: "audio/mpeg"
        )
      end
    end

    trait :active do
      with_assets
      status { "active" }
      published_at { 1.day.ago }
    end

    trait :archived do
      with_assets
      status { "archived" }
      published_at { 2.days.ago }
    end
  end

  factory :training_note do
    # The user brings the firm; a note whose firm_id differs is exactly what
    # belongs_to_same_firm refuses.
    user
    firm { user.firm }
    training
    body { "Saturday ko bank pre-approval slot book karna hai." }
  end
end
