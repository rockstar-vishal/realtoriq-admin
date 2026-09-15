# frozen_string_literal: true

module Api
  module V1
    # Reporting edges. Superadmin only — managers do not edit the graph.
    class UserManagersController < AuthenticatedController
      before_action :require_super_admin
      before_action :set_user

      def create
        manager = current_firm.users.find_by(id: params[:manager_id])
        if manager.nil?
          return render_error("unknown_user", "That user isn't in this firm.", status: :not_found)
        end

        link = UserManager.new(firm: current_firm, user: @user, manager:)
        unless link.save
          return render_link_errors(link)
        end

        AuditEvent.record!(subject: @user, firm: current_firm, actor: current_user,
                           action: "user.manager_added", metadata: { manager_id: manager.id })
        @user.reload
        @user.managers.load
        render json: { user: UserSerializer.detail(@user) }, status: :created
      rescue ActiveRecord::RecordNotUnique
        render_error("invalid", "That reporting line already exists.", status: :unprocessable_content)
      end

      def destroy
        link = @user.manager_links.find_by(manager_id: params[:manager_id])
        if link.nil?
          return render_error("not_found", "Reporting line not found", status: :not_found)
        end

        manager_id = link.manager_id
        link.destroy!
        AuditEvent.record!(subject: @user, firm: current_firm, actor: current_user,
                           action: "user.manager_removed", metadata: { manager_id: })
        @user.reload
        @user.managers.load
        render json: { user: UserSerializer.detail(@user) }, status: :ok
      end

      private

      def set_user
        @user = current_firm.users.find_by(id: params[:user_id])
        return if @user

        render_error("not_found", "User not found", status: :not_found)
      end

      def render_link_errors(link)
        if link.errors.added?(:manager_id, :reporting_cycle)
          return render_error("reporting_cycle", "That reporting line would create a cycle.",
                              status: :unprocessable_content, details: link.errors.to_hash)
        end

        render_error("invalid", link.errors.full_messages.to_sentence,
                     status: :unprocessable_content, details: link.errors.to_hash)
      end
    end
  end
end
