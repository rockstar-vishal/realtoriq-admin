# frozen_string_literal: true

module Admin
  class SessionsController < BaseController
    skip_before_action :require_admin, only: %i[new create]
    layout "admin_bare", only: %i[new create]

    # Sign-in is the one unauthenticated surface in the panel, so it gets a
    # rate limit. Rails 8's built-in limiter is backed by Solid Cache.
    rate_limit to: 10, within: 3.minutes, only: :create,
      with: -> { redirect_to new_admin_session_path, alert: "Too many attempts. Try again in a few minutes." }

    def new
      redirect_to admin_root_path and return if current_admin.present?

      @email = ""
    end

    def create
      admin = AdminUser.authenticate(email: params[:email], password: params[:password])

      if admin
        start_session_for(admin)
        redirect_to admin_root_path, notice: "Signed in."
      else
        # One message for both "no such account" and "wrong password" — telling
        # them apart just confirms which addresses exist.
        @email = params[:email].to_s
        flash.now[:alert] = "That email and password don't match."
        render :new, status: :unprocessable_content
      end
    end

    def destroy
      current_admin_session&.destroy
      cookies.delete(:admin_session_id)
      redirect_to new_admin_session_path, notice: "Signed out."
    end

    private

    def start_session_for(admin)
      session = admin.admin_sessions.create!(
        ip_address: request.remote_ip,
        user_agent: request.user_agent,
        last_seen_at: Time.current
      )

      cookies.signed.permanent[:admin_session_id] = {
        value: session.id,
        httponly: true,
        same_site: :lax,
        secure: Rails.env.production?
      }

      admin.update_column(:last_login_at, Time.current)
    end
  end
end
