# frozen_string_literal: true

module Prospects
  # Name, number, comment, and one inventory link. An interested prospect can
  # change its comment only — the lead is the record of the person from then on.
  class Update
    LOCKED = %i[name mobile project_id property_id].freeze

    Result = Struct.new(:ok?, :prospect, :error_code, :error_message, :error_details, keyword_init: true)

    def initialize(prospect:, attributes:)
      @prospect = prospect
      @attributes = attributes.to_h.with_indifferent_access
    end

    def call
      return locked if prospect.status_interested? && locked_change?

      assign_text
      assigned = assign_inventory
      return assigned if assigned.is_a?(Result)
      return mobile_error(assigned) if assigned.is_a?(Phone::Extraction)

      if prospect.save
        Result.new(ok?: true, prospect:)
      else
        Result.new(ok?: false, prospect:, error_code: "invalid",
          error_message: prospect.errors.full_messages.to_sentence,
          error_details: prospect.errors.to_hash)
      end
    end

    private

    attr_reader :prospect, :attributes

    def locked_change?
      LOCKED.any? { |key| attributes.key?(key) && changing?(key) }
    end

    def changing?(key)
      case key
      when :name then attributes[:name].to_s.strip != prospect.name.to_s
      when :mobile
        extracted = Phone.extract_indian_mobile(attributes[:mobile])
        extracted.mobile != prospect.mobile
      when :project_id then attributes[:project_id].presence != prospect.project_id
      when :property_id then attributes[:property_id].presence != prospect.property_id
      end
    end

    def locked
      Result.new(ok?: false, prospect:, error_code: "prospect_locked",
        error_message: "Name, number, and inventory stay with the lead. You can still edit the comment.")
    end

    def assign_text
      prospect.name = attributes[:name].to_s.strip.presence if attributes.key?(:name)
      prospect.comment = attributes[:comment].to_s.strip.presence if attributes.key?(:comment)
    end

    def assign_inventory
      if attributes.key?(:project_id) && attributes.key?(:property_id) &&
          attributes[:project_id].present? && attributes[:property_id].present?
        return Result.new(ok?: false, prospect:, error_code: "invalid",
          error_message: "A prospect can have a project or a property, not both")
      end

      if attributes.key?(:mobile)
        extracted = Phone.extract_indian_mobile(attributes[:mobile])
        return extracted unless extracted.ok?

        prospect.mobile = extracted.mobile
      end

      applied = apply_project if attributes.key?(:project_id)
      return applied if applied.is_a?(Result)

      applied = apply_property if attributes.key?(:property_id)
      return applied if applied.is_a?(Result)

      nil
    end

    def apply_project
      if attributes[:project_id].blank?
        prospect.project = nil
        return
      end

      resolved = Inventory.project_by_id(attributes[:project_id])
      unless resolved.is_a?(Project)
        return Result.new(ok?: false, prospect:, error_code: "invalid",
          error_message: resolved.presence || "That project isn't one of this firm's records.")
      end

      prospect.project = resolved
      prospect.property = nil
      nil
    end

    def apply_property
      if attributes[:property_id].blank?
        prospect.property = nil
        return
      end

      resolved = Inventory.property_by_id(attributes[:property_id])
      unless resolved.is_a?(Property)
        return Result.new(ok?: false, prospect:, error_code: "invalid",
          error_message: resolved.presence || "That property isn't one of this firm's records.")
      end

      prospect.property = resolved
      prospect.project = nil
      nil
    end

    def mobile_error(extracted)
      Result.new(ok?: false, prospect:, error_code: "invalid", error_message: extracted.error)
    end
  end
end
