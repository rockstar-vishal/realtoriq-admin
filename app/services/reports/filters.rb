# frozen_string_literal: true

module Reports
  # The filter bar shared by the four reports. Status is optional because a
  # booking does not move the lead, so the money reports ignore it.
  class Filters
    TRANSACTION_TYPES = %w[sale rent].freeze
    INVALID_TYPE = "transaction_type must be sale or rent."

    def initialize(params, today: Date.current)
      @params = params
      @window = Window.new(from: params[:from], upto: params[:upto], today:)
    end

    attr_reader :window

    def error
      return window.error if window.error
      return INVALID_TYPE if transaction_type == :invalid

      nil
    end

    def lead_scope(user:, money: false, created: false, status: false)
      scope = money ? Lead.all : Lead.visible_to(user)
      scope = scope.where(transaction_type:) if transaction_type
      types = id_list(:property_type_id)
      scope = scope.where(property_type_id: types) if types.any?
      scope = scope.with_sources(id_list(:source_id), missing: source_missing?)
      assignees = id_list(:assigned_user_id)
      scope = scope.where(assigned_user_id: assignees) if assignees.any?
      if status && status_codes.any?
        scope = scope.where(lead_status_id: LeadStatus.where(code: status_codes).select(:id))
      end
      scope = scope.where(created_at: window.starts_at..window.ends_at) if created
      scope
    end

    def source_missing?
      ActiveModel::Type::Boolean.new.cast(params[:source_missing])
    end

    def source_ids
      id_list(:source_id)
    end

    def status_codes
      id_list(:status)
    end

    def self.list(value)
      Array(value).flatten.flat_map { |item| item.to_s.split(",") }.map(&:strip).compact_blank.uniq
    end

    private

    attr_reader :params

    def transaction_type
      value = params[:transaction_type].to_s.strip
      return nil if value.blank?
      return value if TRANSACTION_TYPES.include?(value)

      :invalid
    end

    def id_list(key)
      self.class.list(params[key])
    end
  end
end
