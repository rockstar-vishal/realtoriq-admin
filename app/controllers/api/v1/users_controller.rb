# frozen_string_literal: true

module Api
  module V1
    class UsersController < AuthenticatedController
      before_action :require_super_admin, only: %i[create update]
      before_action :set_user, only: %i[show update]

      def index
        records = visible_users.includes(:managers).active_first

        render json: { users: records.map { |user| UserSerializer.list(user) } }, status: :ok
      end

      def show
        render json: { user: UserSerializer.detail(@user) }, status: :ok
      end

      def create
        result = ::Users::Create.new(
          firm: current_firm,
          actor: current_user,
          attributes: user_params,
          role: params[:role],
          manager_ids: params[:manager_ids]
        ).call

        render_user_result(result, status: :created)
      end

      def update
        result = ::Users::Update.new(
          user: @user,
          actor: current_user,
          attributes: user_params,
          role: params[:role],
          status: params[:status]
        ).call

        render_user_result(result, status: :ok)
      end

      private

      # Superadmin: the whole firm, including disabled (the team screen re-enables
      # them). Everyone else: active manageables, which is the assign picker.
      def visible_users
        current_user.super_admin? ? current_firm.users : current_user.assignable_users
      end

      def set_user
        @user = visible_users.includes(:managers).find_by(id: params[:id])
        return if @user

        render_error("not_found", "User not found", status: :not_found)
      end

      def user_params
        params.permit(:name, :mobile, :email, :rera_number, :notification_mode)
      end

      def render_user_result(result, status:)
        if result.ok?
          user = result.user
          user.managers.load unless user.association(:managers).loaded?
          return render json: { user: UserSerializer.detail(user) }, status:
        end

        if result.errors
          return render_error("invalid", result.error_message || result.errors.full_messages.to_sentence,
                              status: :unprocessable_content, details: result.errors.to_hash)
        end

        http = result.error_code == "unknown_user" ? :not_found : :unprocessable_content
        render_error(result.error_code, result.error_message, status: http)
      end
    end
  end
end
