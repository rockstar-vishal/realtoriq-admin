# frozen_string_literal: true

module Api
  module V1
    # The `confidential_note` rule lives here, in one place.
    #
    # The client composes share messages, so "confidential comments are never
    # included" can't be a server-composed guarantee. Two things narrow it:
    # the note is absent from `list`, and `shareable` holds exactly the fields
    # that are safe to send a client — so a client building a message from
    # `shareable` cannot reach the note by accident.
    module PropertySerializer
      class << self
        def list(property)
          {
            id: property.id,
            title: property.title,
            listing_for: property.listing_for,
            status: property.status,
            price: property.price,
            carpet_area_sqft: property.carpet_area_sqft,
            rate_per_sqft: property.rate_per_sqft,
            floor_band: property.floor_band,
            available_from: property.available_from,
            typology: property.typology && { id: property.typology_id, name: property.typology.name },
            building: building_summary(property.building),
            cover_photo_url: photo_urls(property).first,
            photo_count: property.photos.attachments.size,
            created_at: property.created_at
            # confidential_note is deliberately absent.
          }
        end

        def detail(property)
          list(property).merge(
            description: property.description,
            # The only response that carries it. The design puts it behind a
            # reveal so it can't appear on a client's screen by accident.
            confidential_note: property.confidential_note,
            photo_urls: photo_urls(property),
            building: building_detail(property.building),
            shareable: shareable(property),
            updated_at: property.updated_at
          )
        end

        # Everything that may go to a client, and nothing else. Add to this
        # deliberately — anything put here can end up in a WhatsApp message.
        def shareable(property)
          {
            title: property.title,
            listing_for: property.listing_for,
            price: property.price,
            carpet_area_sqft: property.carpet_area_sqft,
            rate_per_sqft: property.rate_per_sqft,
            floor_band: property.floor_band,
            available_from: property.available_from,
            description: property.description,
            building_name: property.building&.name,
            locality: property.building&.locality&.name,
            city: property.building&.city&.name,
            has_pool: property.building&.has_pool,
            has_gym: property.building&.has_gym,
            photo_urls: photo_urls(property)
          }
        end

        private

        def building_summary(building)
          return nil if building.nil?

          {
            id: building.id, name: building.name,
            locality: building.locality&.name, city: building.city&.name
          }
        end

        def building_detail(building)
          return nil if building.nil?

          building_summary(building).merge(
            address: building.address,
            lat: building.lat&.to_f, lng: building.lng&.to_f,
            google_place_id: building.google_place_id,
            has_pool: building.has_pool, has_gym: building.has_gym
          )
        end

        # Attachment ids are UUIDv7, so ordering by id is creation order and the
        # first is the cover. The design shows no reordering, so none exists.
        def photo_urls(property)
          property.photos.attachments.sort_by(&:id).map { |a| BlobUrl.call(a) }
        end
      end
    end
  end
end
