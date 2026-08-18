# frozen_string_literal: true

module Admin
  # Every admin screen inherits from here.
  #
  # This is the one place in the application that lifts the tenant scope. The
  # admin panel's entire purpose is to work across firms, so the bypass is set
  # here and nowhere else — the broker API must never touch it.
  class BaseController < ApplicationController
    layout "admin"

    before_action :require_admin
    before_action :bypass_firm_scope
    before_action :set_audit_context

    private

    def current_admin_session
      return @current_admin_session if defined?(@current_admin_session)

      @current_admin_session = begin
        id = cookies.signed[:admin_session_id]
        session = id.present? ? AdminSession.includes(:admin_user).find_by(id:) : nil

        if session.nil? || session.expired? || !session.admin_user.active?
          session&.destroy
          nil
        else
          session
        end
      end
    end

    def current_admin = current_admin_session&.admin_user

    helper_method :current_admin

    def require_admin
      return if current_admin.present?

      cookies.delete(:admin_session_id)
      redirect_to new_admin_session_path, alert: "Please sign in to continue."
    end

    def bypass_firm_scope
      Current.firm_scope_bypassed = true
    end

    def set_audit_context
      Current.admin_user = current_admin
      Current.request_ip = request.remote_ip
      Current.user_agent = request.user_agent
      current_admin_session&.touch_seen!
    end
  end
end
