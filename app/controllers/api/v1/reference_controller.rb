# frozen_string_literal: true

module Api
  module V1
    # The masters bundle every dropdown in the app depends on, in one request.
    #
    # Global data, identical for every firm, so it is cached and carries an
    # ETag — the app can revalidate cheaply on each launch instead of
    # re-downloading the whole thing.
    class ReferenceController < AuthenticatedController
      def index
        payload = Rails.cache.fetch(cache_key, expires_in: 1.hour) { build_payload }

        # fresh_when short-circuits with 304 when the client's copy is current.
        return unless stale?(etag: payload, public: false)

        render json: payload, status: :ok
      end

      private

      # Keyed by firm, because builders are no longer purely global: the payload
      # carries the platform's list plus this firm's own. Everything else here
      # is identical for everyone, so this is the one thing that costs us the
      # shared cache entry.
      def cache_key
        [ "api/v1/reference", current_firm.id,
          City.maximum(:updated_at), Locality.maximum(:updated_at),
          builders.maximum(:updated_at), Typology.maximum(:updated_at),
          LeadSource.maximum(:updated_at), LeadStatus.maximum(:updated_at),
          PropertyType.maximum(:updated_at) ].map(&:to_s).join("/")
      end

      def builders = Builder.available_to(current_firm)

      def build_payload
        {
          cities: City.active.alphabetical.map { |c|
            { id: c.id, name: c.name, state: c.state, state_code: c.state_code }
          },
          localities: Locality.active.alphabetical.map { |l|
            { id: l.id, city_id: l.city_id, name: l.name, pincode: l.pincode }
          },
          builders: builders.active.alphabetical.map { |b|
            { id: b.id, name: b.name, global: b.global? }
          },
          typologies: Typology.active.ordered.map { |t|
            { id: t.id, name: t.name, code: t.code, bedrooms: t.bedrooms&.to_f }
          },
          lead_sources: LeadSource.active.ordered.map { |s|
            { id: s.id, name: s.name, code: s.code, category: s.category }
          },
          lead_statuses: LeadStatus.active.ordered.map { |s|
            { id: s.id, name: s.name, code: s.code, is_dead: s.is_dead, is_booked: s.is_booked }
          },
          property_types: PropertyType.active.ordered.map { |t|
            { id: t.id, name: t.name, code: t.code }
          },
          # Fixed enums the app needs but which aren't worth a table.
          transaction_types: [ { code: "sale", name: "Sale" }, { code: "rent", name: "Rent" } ],
          floor_bands: %w[lower middle higher].map { |c| { code: c, name: c.humanize } }
        }
      end
    end
  end
end
