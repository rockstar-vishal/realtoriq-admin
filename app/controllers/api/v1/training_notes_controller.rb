# frozen_string_literal: true

module Api
  module V1
    # One running note per broker per training, saved in place.
    #
    # PUT rather than POST: the client holds one text area and sends whatever is
    # in it. Sending it empty clears the note.
    class TrainingNotesController < AuthenticatedController
      def update
        training = Training.live.find_by(id: params[:training_id])
        return not_found if training.nil?

        body = note_body
        return render_error("invalid_request", "body must be text.", status: :bad_request) if body == :invalid

        if body.blank?
          existing(training)&.destroy
          return render json: { note: nil }, status: :ok
        end

        if body.length > TrainingNote::BODY_MAX
          return render_error("note_too_long",
                              "A note can be up to #{TrainingNote::BODY_MAX} characters.",
                              status: :unprocessable_content)
        end

        note = existing(training) || TrainingNote.new(user: current_user, training:)
        note.body = body
        note.save!

        render json: { note: { body: note.body, updated_at: note.updated_at } }, status: :ok
      end

      private

      def existing(training)
        TrainingNote.find_by(user_id: current_user.id, training_id: training.id)
      end

      # Accepts { "body": "…" } and { "note": { "body": "…" } }.
      #
      # A body that isn't text is refused rather than ignored. The API ignores
      # misshapen params elsewhere by design, but here "ignored" would read as
      # "cleared", and a broker's notes would vanish on a client bug.
      def note_body
        value = params.key?(:body) ? params[:body] : params.dig(:note, :body)
        return "" if value.nil?
        return :invalid unless value.is_a?(String)

        value
      end
    end
  end
end
