# frozen_string_literal: true

module Api
  module V1
    module ProjectSerializer
      class << self
        def list(project)
          {
            id: project.id,
            name: project.name,
            status: project.status,
            source: project.source,
            builder: project.builder && { id: project.builder_id, name: project.builder.name },
            city: project.city&.name,
            locality: project.locality&.name,
            starting_budget: project.starting_budget,
            # Derived from the typologies, never stored — a stored band can end
            # up disagreeing with the rows it came from.
            price_band: project.price_band,
            area_band: project.area_band,
            possession_on: project.possession_on,
            possession_display: project.possession_display,
            brokerage_percent: project.brokerage_percent&.to_f,
            promo: project.promo_live? ? { text: project.promo_text, ends_on: project.promo_ends_on } : nil,
            configurations: project.typologies.map(&:name),
            cover_photo_url: photo_urls(project).first,
            photo_count: project.photos.attachments.size,
            created_at: project.created_at
          }
        end

        def detail(project)
          list(project).merge(
            rera_number: project.rera_number,
            address: project.address,
            lat: project.lat&.to_f,
            lng: project.lng&.to_f,
            google_place_id: project.google_place_id,
            typologies: project.project_typologies.map { |pt| typology(pt) },
            photos: photos(project),
            photo_urls: photo_urls(project),
            brochure_url: project.brochure.attached? ? BlobUrl.call(project.brochure) : nil,
            external_ref: project.external_ref,
            shareable: shareable(project),
            updated_at: project.updated_at
          )
        end

        # Everything safe to send a client. Projects carry no confidential
        # field today, but the subset exists so the client has one consistent
        # place to build a share message from — the same contract as properties.
        def shareable(project)
          {
            name: project.name,
            builder_name: project.builder&.name,
            city: project.city&.name,
            locality: project.locality&.name,
            starting_budget: project.starting_budget,
            price_band: project.price_band,
            area_band: project.area_band,
            possession_display: project.possession_display,
            rera_number: project.rera_number,
            configurations: project.typologies.map(&:name),
            promo_text: project.promo_live? ? project.promo_text : nil,
            photo_urls: photo_urls(project),
            brochure_url: project.brochure.attached? ? BlobUrl.call(project.brochure) : nil
            # brokerage_percent is deliberately absent: what the broker earns is
            # not the client's business.
          }
        end

        private

        def typology(project_typology)
          {
            id: project_typology.id,
            typology_id: project_typology.typology_id,
            name: project_typology.typology&.name,
            starting_price: project_typology.starting_price,
            starting_carpet_sqft: project_typology.starting_carpet_sqft,
            rate_per_sqft: project_typology.rate_per_sqft
          }
        end

        # Attachment ids are UUIDv7, so ordering by id is creation order and the
        # first is the cover. The design shows no reordering, so none exists.
        def photo_attachments(project) = project.photos.attachments.sort_by(&:id)

        # Carries the attachment id, which `photo_urls` does not — and without
        # it DELETE /projects/:id/photos/:photo_id was uncallable: the id
        # appeared in no response, and the signed blob URL encodes the *blob*
        # id, which is a different record. Detail only. `shareable` keeps the
        # bare urls, because an id is of no use to a client and share payloads
        # get pasted into WhatsApp.
        def photos(project)
          photo_attachments(project).map { |a| { id: a.id, url: BlobUrl.call(a) } }
        end

        def photo_urls(project) = photo_attachments(project).map { |a| BlobUrl.call(a) }
      end
    end
  end
end
