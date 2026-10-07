# frozen_string_literal: true

module Api
  module V1
    # A website posts here with the firm's key. The firm comes from that key,
    # never from the body. Not a broker JWT.
    #
    # Size and address checks are prepended so they run before BaseController
    # reads params. A new unrecognised bearer does not get its own limit.
    class InboundLeadsController < BaseController
      prepend_before_action :reject_inbound_flood
      prepend_before_action :reject_oversized_enquiry

      def create
        credential = InboundCredential.authenticate(bearer_token)
        if credential.nil?
          Inbound::Throttle.record_failure(request.remote_ip)
          return render_error("unauthorized", "This key is not valid.", status: :unauthorized)
        end

        channel = request.path_parameters[:channel].to_s
        kind = request.path_parameters[:kind].to_s
        return render_error("not_found", "Not found", status: :not_found) unless Inbound::Channels.known?(channel)
        return render_error("not_found", "Not found", status: :not_found) unless Inbound::Channels.kind?(kind)
        unless Inbound::Throttle.allow_key?(credential.token_digest)
          return render_error("rate_limited", "Too many enquiries. Try again shortly.", status: :too_many_requests)
        end

        result = Inbound::ReceiveLead.call(
          firm: credential.firm, channel:, kind:, payload: request_payload
        )
        if result.ok?
          render json: { status: result.status }, status: :ok
        else
          render_error("invalid", result.error, status: :unprocessable_content)
        end
      end

      private

      def reject_oversized_enquiry
        return if Inbound::Throttle.body_within_limit?(request)

        render_error("invalid", "This enquiry is too large.", status: :content_too_large)
      end

      def reject_inbound_flood
        return if Inbound::Throttle.allow_ip?(request.remote_ip)

        render_error("rate_limited", "Too many enquiries. Try again shortly.", status: :too_many_requests)
      end

      def bearer_token
        header = request.headers["Authorization"].to_s
        return if header.blank?
        return unless header.start_with?("Bearer ")

        header.split(" ", 2).last.presence
      end

      def request_payload
        params.permit(
          :name, :mobile, :email, :listing, :enquiry_id, :budget, :city, :locality,
          :configuration, :transaction_type
        ).to_h
      end
    end
  end
end
