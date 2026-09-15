# frozen_string_literal: true

module Users
  # Superadmin-only. Ops created the firm and its one superadmin; everyone else
  # is added here. They can sign in immediately — there is no invite SMS.
  class Create
    Result = Struct.new(:ok?, :user, :error_code, :error_message, :errors, keyword_init: true)

    CREATABLE_ROLES = %w[manager agent].freeze

    def initialize(firm:, actor:, attributes:, role: nil, manager_ids: [])
      @firm = firm
      @actor = actor
      @attributes = attributes.to_h.symbolize_keys.except(:status, :firm_id, :manager_ids, :id, :role)
      @role = role
      @manager_ids = Array(manager_ids).compact_blank.uniq
    end

    def call
      user = firm.users.new(attributes)
      user.role = role if role.present?
      return invalid_role(user) unless CREATABLE_ROLES.include?(user.role.to_s)

      managers = load_managers
      return managers if managers.is_a?(Result)

      persist(user, managers)
    end

    private

    attr_reader :firm, :actor, :attributes, :role, :manager_ids

    def persist(user, managers)
      created = nil

      User.transaction do
        firm.lock!
        if over_user_limit?
          return Result.new(
            ok?: false,
            error_code: "user_limit_reached",
            error_message: "This plan's user limit has been reached."
          )
        end

        user.save!
        managers.each { |manager| UserManager.create!(firm:, user:, manager:) }
        created = user
      end

      created = User.across_firms.includes(:managers).find(created.id)
      AuditEvent.record!(subject: created, firm:, actor:, action: "user.created",
                         metadata: { role: created.role })
      Result.new(ok?: true, user: created)
    rescue ActiveRecord::RecordInvalid => e
      Result.new(ok?: false, user: e.record, errors: e.record.errors, error_code: "invalid",
                 error_message: e.record.errors.full_messages.to_sentence)
    end

    def load_managers
      return [] if manager_ids.empty?

      found = firm.users.where(id: manager_ids).to_a
      if found.size != manager_ids.size
        return Result.new(
          ok?: false,
          error_code: "unknown_user",
          error_message: "That user isn't in this firm."
        )
      end
      if found.any?(&:super_admin?)
        user = firm.users.new
        user.errors.add(:manager_ids, "the super admin is not part of the reporting graph")
        return Result.new(ok?: false, user:, errors: user.errors, error_code: "invalid",
                          error_message: user.errors.full_messages.to_sentence)
      end

      found
    end

    def over_user_limit?
      max = firm.current_subscription&.plan&.max_users
      return false if max.nil?

      # Disabled accounts still occupy a seat — disabling is not a way around
      # the plan.
      firm.users.count >= max
    end

    def invalid_role(user)
      user.errors.add(:role, "must be manager or agent")
      Result.new(ok?: false, user:, errors: user.errors, error_code: "invalid",
                 error_message: user.errors.full_messages.to_sentence)
    end
  end
end
