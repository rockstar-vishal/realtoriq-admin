# frozen_string_literal: true

module Admin
  module Firms
    # Ops-side verification actions. Each responds into the channel's own turbo
    # frame so a click swaps one row rather than reloading the page.
    class ContactChannelsController < Admin::BaseController
      before_action :set_firm
      before_action :set_channel

      def send_code
        result = Verifications::SendCode.new(channel: @channel, ip: request.remote_ip).call

        if result.ok?
          AuditEvent.record!(subject: @channel, firm: @firm, action: "channel.code_sent",
                             metadata: { kind: @channel.kind })
          respond_with_row(notice: "Code sent to #{@channel.display_value}.")
        else
          respond_with_row(alert: result.error)
        end
      end

      # Ops confirming out of band — they called the firm, or saw the documents.
      # Distinct from the firm proving it themselves via a code, which is why
      # verified_by_user stays null here.
      def mark_verified
        @channel.mark_verified!
        AuditEvent.record!(subject: @channel, firm: @firm, action: "channel.verified_by_admin",
                           metadata: { kind: @channel.kind })

        respond_with_row(notice: "#{@channel.kind.humanize} marked verified.")
      end

      def reset
        @channel.reset_verification!
        AuditEvent.record!(subject: @channel, firm: @firm, action: "channel.verification_reset",
                           metadata: { kind: @channel.kind })

        respond_with_row(notice: "#{@channel.kind.humanize} verification cleared.")
      end

      private

      def set_firm
        @firm = Firm.find_by!(slug: params[:firm_slug])
      end

      def set_channel
        @channel = @firm.contact_channels.find(params[:id])
      end

      def respond_with_row(notice: nil, alert: nil)
        flash.now[:notice] = notice if notice
        flash.now[:alert] = alert if alert

        respond_to do |format|
          format.turbo_stream do
            render turbo_stream: turbo_stream.replace(
              helpers.dom_id(@channel),
              partial: "admin/firms/channel_row",
              locals: { channel: @channel, firm: @firm }
            )
          end
          format.html { redirect_to admin_firm_path(@firm, tab: "verification"), notice:, alert: }
        end
      end
    end
  end
end
