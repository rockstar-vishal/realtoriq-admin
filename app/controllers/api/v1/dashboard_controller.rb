# frozen_string_literal: true

module Api
  module V1
    # The home screen, in one request.
    #
    # No role guard: the service decides what this caller may see, and an agent
    # simply gets a payload with no `money` block rather than a 403 — the screen
    # is legitimately theirs, just smaller.
    class DashboardController < AuthenticatedController
      def show
        render json: ::Dashboard::Summary.new(user: current_user).call, status: :ok
      end
    end
  end
end
