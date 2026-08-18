# frozen_string_literal: true

module Api
  module V1
    # The platform's curated developers plus the firm's own.
    #
    # The design puts an inline create on the project form, so a broker is never
    # blocked mid-form by a missing builder. What they add is theirs alone — it
    # does not reach the global list or any other firm.
    class BuildersController < AuthenticatedController
      def index
        builders = Builder.available_to(current_firm).active.alphabetical

        render json: { builders: builders.map { |b| BuilderSerializer.call(b) } }, status: :ok
      end

      def create
        builder = Builder.new(builder_params)
        builder.firm = current_firm

        unless builder.save
          return render_error("invalid", builder.errors.full_messages.to_sentence,
                              status: :unprocessable_content, details: builder.errors.to_hash)
        end

        render json: { builder: BuilderSerializer.call(builder) }, status: :created
      end

      private

      def builder_params = params.permit(:name, :website)
    end
  end
end
