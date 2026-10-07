# frozen_string_literal: true

module Users
  # Superadmin-only. Role changes stay inside manager/agent; the unique
  # superadmin cannot be demoted or disabled from here (that would lock the
  # firm out of user management). Disable revokes every live session.
  class Update
    Result = Struct.new(:ok?, :user, :error_code, :error_message, :errors, keyword_init: true)

    UPDATABLE_ROLES = %w[manager agent].freeze

    def initialize(user:, actor:, attributes:, role: nil, status: nil)
      @user = user
      @actor = actor
      @attributes = attributes.to_h.symbolize_keys.slice(
        :name, :mobile, :email, :rera_number, :notification_mode
      )
      @attributes[:role] = role unless role.nil?
      @attributes[:status] = status unless status.nil?
    end

    def call
      return cannot_alter_super_admin if user.super_admin? && touching_protected_super_admin_fields?
      return cannot_promote if promoting_to_super_admin?
      return invalid_role if changing_to_unknown_role?

      was_active = user.active?

      User.transaction do
        user.assign_attributes(attributes)
        user.save!
        revoke_sessions! if was_active && user.disabled?
      end

      AuditEvent.record!(subject: user, firm: user.firm, actor:, action: audit_action,
                         metadata: { role: user.role, status: user.status })
      Result.new(ok?: true, user:)
    rescue ActiveRecord::RecordInvalid => e
      Result.new(ok?: false, user: e.record, errors: e.record.errors, error_code: "invalid",
                 error_message: e.record.errors.full_messages.to_sentence)
    end

    private

    attr_reader :user, :actor, :attributes

    def touching_protected_super_admin_fields?
      (attributes.key?(:role) && attributes[:role].to_s != user.role) ||
        (attributes.key?(:status) && attributes[:status].to_s != user.status)
    end

    def promoting_to_super_admin?
      attributes[:role].to_s == "super_admin" && !user.super_admin?
    end

    def changing_to_unknown_role?
      attributes.key?(:role) && UPDATABLE_ROLES.exclude?(attributes[:role].to_s)
    end

    def revoke_sessions!
      user.auth_sessions.where(revoked_at: nil).find_each do |session|
        session.revoke!("account_disabled")
      end
    end

    def audit_action
      return "user.disabled" if user.disabled? && user.status_previously_changed?

      "user.updated"
    end

    def cannot_alter_super_admin
      Result.new(
        ok?: false,
        error_code: "invalid",
        error_message: "The super admin cannot be disabled or have their role changed."
      )
    end

    def cannot_promote
      Result.new(
        ok?: false,
        error_code: "invalid",
        error_message: "A firm has exactly one super admin."
      )
    end

    def invalid_role
      user.errors.add(:role, "must be manager or agent")
      Result.new(ok?: false, user:, errors: user.errors, error_code: "invalid",
                 error_message: user.errors.full_messages.to_sentence)
    end
  end
end
