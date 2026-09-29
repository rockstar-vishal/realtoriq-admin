# frozen_string_literal: true

module Turbo
  # Inbound from turbo-rails8. The body is signed, so it is read raw and not
  # re-serialized. Errors are a string so the public enquiry form can show them.
  class EventsController < ActionController::API
    def create
      body = request.raw_post
      unless Realtoriq::Signature.valid?(body, request.headers["X-RealtorIQ-Signature"])
        return render json: { error: "Unauthorized" }, status: :unauthorized
      end

      payload = JSON.parse(body)
      unless payload.is_a?(Hash)
        return render json: { error: "Invalid JSON" }, status: :bad_request
      end

      result = if payload["event"] == "enquiry"
        Realtoriq::ReceiveEnquiry.call(payload)
      else
        Realtoriq::IngestProject.call(payload)
      end

      if result.ok?
        render json: { ok: true }, status: result.status
      else
        render json: { error: result.error }, status: result.status
      end
    rescue JSON::ParserError
      render json: { error: "Invalid JSON" }, status: :bad_request
    end
  end
end
