# frozen_string_literal: true

module Inventory
  # A public path segment. Assigned once, from the name or title, and left
  # alone when that text changes so a link that was already shared still works.
  module PublicSlug
    extend ActiveSupport::Concern

    FORMAT = /\A[a-z0-9]+(?:-[a-z0-9]+)*\z/
    MAX = 60

    included do
      before_validation :assign_public_slug, if: :needs_public_slug?
      validates :slug, presence: true, if: :slug_required?
      validates :slug, format: { with: FORMAT }, allow_nil: true
      validate :slug_unique_in_firm, if: -> { slug.present? && firm_id.present? }
    end

    class << self
      # `taken` is a hash of slug => true for the firm already processed.
      # Callers that mint one slug pass a fresh hash; the database is the
      # backstop when two creates race.
      def mint(text, taken = {})
        base = text.to_s.parameterize.presence || "listing"
        base = base[0, 48].sub(/-\z/, "").presence || "listing"
        candidate = base
        n = 2
        while taken[candidate]
          suffix = "-#{n}"
          candidate = "#{base[0, MAX - suffix.length].sub(/-\z/, '')}#{suffix}"
          n += 1
          break if n > 200
        end
        taken[candidate] = true
        candidate
      end
    end

    def needs_public_slug?
      slug.blank? && firm_id.present?
    end

    def slug_required?
      firm_id.present?
    end

    def assign_public_slug
      taken = self.class.unscoped.where(firm_id:).where.not(slug: nil).pluck(:slug).index_with(true)
      self.slug = PublicSlug.mint(public_slug_source, taken)
    end

    def public_slug_source
      raise NotImplementedError, "#{self.class} needs public_slug_source"
    end

    # Unscoped on purpose. Project's default scope is `none` when no tenant is
    # set, and a scoped uniqueness check would then miss the clash.
    def slug_unique_in_firm
      clash = self.class.unscoped.where(firm_id:, slug:)
      clash = clash.where.not(id:) if id.present?
      errors.add(:slug, "has already been taken") if clash.exists?
    end
  end
end
