# frozen_string_literal: true

module Api
  module V1
    class MatchDigestsController < AuthenticatedController
      def show
        return render_error("not_found", "Match digest not found", status: :not_found) unless current_user.super_admin?

        digest = MatchDigest.find_by(firm_id: current_firm.id)
        render json: { match_digest: digest && MatchDigestSerializer.call(digest) }, status: :ok
      end
    end
  end
end
