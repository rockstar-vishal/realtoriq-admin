# frozen_string_literal: true

module Api
  module V1
    # The firm's three contact channels, as shown on the Settings screen.
    #
    # Any user can see them; only the super admin can act on them. That split is
    # enforced here, not in the client.
    class ContactChannelsController < AuthenticatedController
      before_action :require_super_admin, only: %i[request_code verify]
      before_action :set_channel, only: %i[request_code verify]

      def index
        render json: {
          channels: current_firm.contact_channels.ordered.map { |c| serialize(c) },
          can_verify: current_user.can_manage_firm_settings?
        }, status: :ok
      end

      def request_code
        result = Verifications::SendCode.new(channel: @channel, ip: request.remote_ip).call

        if result.ok?
          AuditEvent.record!(subject: @channel, firm: current_firm, actor: current_user,
                             action: "channel.code_sent", metadata: { kind: @channel.kind })

          render json: {
            channel: serialize(@channel.reload),
            expires_in: ContactChannel::CODE_TTL.to_i
          }, status: :ok
        else
          render_error("code_not_sent", result.error, status: :unprocessable_content)
        end
      end

      def verify
        code = OneTimeCode.usable.where(contact_channel: @channel).order(created_at: :desc).first

        return render_error("invalid_code", "That code has expired. Request a new one.", status: :unprocessable_content) if code.nil?

        unless code.verify(params.require(:code))
          @channel.increment!(:verification_attempts)
          @channel.update!(verification_state: :failed) if code.exhausted?

          return render_error("invalid_code", "That code isn't right.", status: :unprocessable_content,
                              details: { attempts_left: [ code.max_attempts - code.attempts, 0 ].max })
        end

        @channel.mark_verified!(by: current_user)
        AuditEvent.record!(subject: @channel, firm: current_firm, actor: current_user,
                           action: "channel.verified_by_firm", metadata: { kind: @channel.kind })

        render json: { channel: serialize(@channel) }, status: :ok
      end

      private

      def set_channel
        # Scoped through the firm, so an id from another tenant simply isn't found.
        @channel = current_firm.contact_channels.find(params[:id])
      end

      def serialize(channel)
        {
          id: channel.id,
          kind: channel.kind,
          value: channel.value,
          display_value: channel.display_value,
          state: channel.verification_state,
          verified: channel.verified?,
          verified_at: channel.verified_at,
          resend_available_at: channel.resend_available_at
        }
      end
    end
  end
end
