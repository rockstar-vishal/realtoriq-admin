# frozen_string_literal: true

module Api
  module V1
    # Skills & Trainings, as brokers see them: the active ones that have not
    # passed their date, newest first. Every role reads these — there is no
    # money and nothing tenant-specific in a training.
    class TrainingsController < AuthenticatedController
      def index
        @pagy, records = pagy(
          Training.live.newest_first.with_attached_banner, limit: 25
        )

        render json: {
          trainings: records.map { |training| TrainingSerializer.card(training) },
          meta: pagination_meta(@pagy)
        }, status: :ok
      end

      def show
        training = Training.live.includes(:created_by_admin_user)
          .with_attached_banner.with_attached_document.with_attached_podcast
          .find_by(id: params[:id])
        # A draft, an archived or an expired training is 404 rather than 403:
        # the same rule the rest of the API follows — never confirm that a row
        # the caller may not read exists.
        return not_found if training.nil?

        note = TrainingNote.find_by(user_id: current_user.id, training_id: training.id)

        render json: { training: TrainingSerializer.detail(training, note:) }, status: :ok
      end
    end
  end
end
