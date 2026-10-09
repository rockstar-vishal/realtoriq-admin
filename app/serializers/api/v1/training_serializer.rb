# frozen_string_literal: true

module Api
  module V1
    # The list card and the detail payload for Skills & Trainings.
    #
    # URLs are permanent (BlobUrl.call, not .sensitive): a training is teaching
    # material the app re-renders whenever the broker opens it, and a 20-minute
    # audio element that expires mid-listen would be worse than the risk a
    # forwarded link carries. Decided with the owner, 28 Sep 2026.
    #
    # The guide is proxied, not redirected. pdf.js fetches it, and the redirect
    # to S3 is the response the browser rejects. The banner and the podcast
    # stay redirects: an image and an audio element never read the body.
    module TrainingSerializer
      def self.card(training)
        {
          id: training.id,
          title: training.title,
          description: training.description,
          language: training.language,
          language_label: training.language_label,
          banner_url: BlobUrl.call(training.banner),
          # A date or null. "Expiring: Never" is the client's wording.
          valid_upto: training.valid_upto,
          podcast_duration_seconds: training.podcast_duration_seconds,
          published_at: training.published_at
        }
      end

      def self.detail(training, note: nil)
        card(training).merge(
          intro_text: training.intro_text,
          # Null means ops left it blank and the app shows its own default steps.
          instructions_text: training.instructions_text.presence,
          document_url: BlobUrl.proxy(training.document),
          podcast_url: podcast_url(training),
          created_by_name: training.created_by_name,
          note: note && { body: note.body, updated_at: note.updated_at }
        )
      end

      # An uploaded file wins over a pasted link, so swapping a link for a file
      # does not need the link cleared first.
      def self.podcast_url(training)
        return BlobUrl.call(training.podcast) if training.podcast.attached?

        training.podcast_url.presence
      end
    end
  end
end
