# frozen_string_literal: true

module Api
  module V1
    module Facebook
      class ConnectionsController < BaseController
        def create
          attempt = FacebookOauthAttempt.across_firms.find_by(id: params[:attempt_id])
          return render_facebook_error("expired") if attempt.nil?

          unless owns?(attempt) && nonce_matches?(attempt)
            Current.set(firm: attempt.firm) { attempt.void!(error_code: "wrong_browser") }
            return render_facebook_error("not_yours")
          end

          return render_facebook_error("expired") if attempt.expired?
          return render_facebook_error("already_used") if attempt.consumed?
          return render_facebook_error(attempt.error_code.presence || "exchange_failed") if attempt.failed?
          return render_facebook_error("expired") unless attempt.completed?

          result = nil
          attempt.with_lock do
            attempt.reload
            unless attempt.completed?
              result = refused_status(attempt)
              next
            end

            result = ::Facebook::StoreConnection.call(attempt:, actor: current_user)
          end

          if result.ok?
            refreshed = ::Facebook::StoreConnection.refresh(result.connection, result.kept_ids)
            render json: integration_payload(warnings: Array(result.warnings) + refreshed)
          else
            render_facebook_error(result.error_code, details: result.details)
          end
        end

        private

        def owns?(attempt)
          attempt.user_id == current_user.id && attempt.firm_id == current_firm.id
        end

        def nonce_matches?(attempt)
          digest = Digest::SHA256.hexdigest(params[:nonce].to_s)
          stored = attempt.nonce_digest.to_s
          return false if stored.blank? || digest.bytesize != stored.bytesize

          ActiveSupport::SecurityUtils.secure_compare(digest, stored)
        end

        def refused_status(attempt)
          code = if attempt.expired?
            "expired"
          elsif attempt.consumed?
            "already_used"
          elsif attempt.failed?
            attempt.error_code.presence || "exchange_failed"
          else
            "expired"
          end
          ::Facebook::StoreConnection::Result.new(ok?: false, error_code: code)
        end
      end
    end
  end
end
