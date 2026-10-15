# frozen_string_literal: true

module Onboarding
  class VerificationsController < BaseController
    before_action :known_kind

    def send_code
      @form = RegistrationForm.from_params(params)
      answer SendCode.new(kind: params[:kind], form: @form, sitting:, request:).call, @form
    end

    def verify_code
      @form = RegistrationForm.from_params(params)
      answer VerifyCode.new(kind: params[:kind], form: @form, sitting:).call, @form
    end

    def change
      @form = RegistrationForm.from_params(params)
      sitting.forget!(params[:kind])
      respond_to do |format|
        format.html { render_show(ok: true) }
        format.json { render json: { ok: true, state: "idle", message: "" } }
      end
    end

    private

    def known_kind
      head :not_found unless %w[mobile whatsapp email].include?(params[:kind])
    end

    def answer(result, form)
      respond_to do |format|
        format.html { render_show(ok: result.ok, message: result.message) }
        format.json do
          body = json_for(result, form)
          render json: body, status: (body[:ok] ? :ok : :unprocessable_content)
        end
      end
    end

    # The posted form, not a redirect. A redirect would drop everything except
    # the contacts, and without JavaScript there is no other copy of it.
    def render_show(ok:, message: nil)
      load_choices
      if message.present?
        ok ? flash.now[:notice] = message : flash.now[:alert] = message
      end
      lookup_context.prefixes.unshift("onboarding/applications")
      render "onboarding/applications/show", status: (ok ? :ok : :unprocessable_content)
    end

    def json_for(result, form)
      value = form.public_send(params[:kind])
      already = result.message == Onboarding::ALREADY_VERIFIED
      state = sitting.state(params[:kind], value)
      payload = { ok: result.ok || already, state:, message: json_message(result, value, already) }
      payload[:resend_in] = resend_in if state == "sent"
      payload
    end

    def json_message(result, value, already)
      return "Already verified." if already
      return "" if result.ok && action_name == "verify_code"
      return sent_copy(value) if result.ok && action_name == "send_code"

      result.message
    end

    def sent_copy(value)
      shown = helpers.signup_contact_display(params[:kind], value)
      case params[:kind]
      when "email" then "Code emailed to #{shown}."
      when "whatsapp" then "Code sent on WhatsApp to #{shown}."
      else "Code sent by SMS to #{shown}."
      end
    end

    def resend_in
      sent = sitting.sent_at(params[:kind])
      return 0 if sent.blank?

      [ (sent + ContactChannel::RESEND_COOLDOWN - Time.current).floor, 0 ].max
    end
  end
end
