# frozen_string_literal: true

module Prospects
  # Resolves a project or property a broker pointed at, by code on import and
  # by id when editing or converting. A project may be this firm's or a
  # marketplace row. A property must belong to this firm.
  class Inventory
    def self.project_by_code(token)
      new.project_by_code(token)
    end

    def self.property_by_code(token)
      new.property_by_code(token)
    end

    def self.project_by_id(id)
      new.project_by_id(id)
    end

    def self.property_by_id(id)
      new.property_by_id(id)
    end

    def project_by_code(token)
      token = token.to_s.strip
      return "Unknown project code." if token.blank?
      return "Put the property code in Property code, not Project code." if token.match?(/\AH-/i)

      code = token.upcase
      own = Project.where("upper(code) = ?", code).first
      return gate_project(own) if own

      market = Project.marketplace.where("upper(code) = ? OR upper(external_ref) = ?", code, code).first
      return market if market

      archived = Project.unscoped.where(firm_id: nil).where("upper(code) = ?", code).first
      return "That project is archived." if archived&.archived?

      "Unknown project code #{token}."
    end

    def property_by_code(token)
      token = token.to_s.strip
      return "Unknown property code." if token.blank?
      return "Put the project code in Project code, not Property code." if token.match?(/\AP-/i)

      own = Property.where("upper(code) = ?", token.upcase).first
      return gate_property(own) if own

      "Unknown property code #{token}."
    end

    def project_by_id(id)
      return nil if id.blank?

      own = Project.find_by(id:)
      return gate_project(own) if own

      market = Project.marketplace.find_by(id:)
      return market if market

      archived = Project.unscoped.find_by(id:, firm_id: nil)
      return "That project is archived." if archived&.archived?

      "That project isn't one of this firm's records."
    end

    def property_by_id(id)
      return nil if id.blank?

      own = Property.find_by(id:)
      return gate_property(own) if own

      "That property isn't one of this firm's records."
    end

    private

    def gate_project(project)
      return "That project is archived." if project.archived?

      project
    end

    def gate_property(property)
      return "That property is sold." if property.sold_out?

      property
    end
  end
end
