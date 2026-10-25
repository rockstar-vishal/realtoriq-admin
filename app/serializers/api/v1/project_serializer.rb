# frozen_string_literal: true

module Api
  module V1
    module ProjectSerializer
      class << self
        def list(project, category: nil)
          {
            id: project.id,
            code: project.code,
            name: project.name,
            status: project.status,
            source: project.source,
            builder: project.builder && { id: project.builder_id, name: project.builder.name },
            city: project.city&.name,
            city_id: project.city_id,
            locality: project.locality&.name,
            locality_id: project.locality_id,
            starting_budget: project.starting_budget,
            categories: project.categories,
            starting_prices: project.starting_prices,
            price_summary: project.price_summary(category:),
            **(category.present? ? { display_starting_price: project.starting_price_for(category) } : {}),
            # Unweighted mean of config rates; null when none can produce a rate.
            avg_psf: project.avg_psf,
            # Derived from the typologies, never stored — a stored band can end
            # up disagreeing with the rows it came from.
            price_band: project.price_band,
            area_band: project.area_band,
            possession_on: project.possession_on,
            possession_display: project.possession_display,
            brokerage_percent: project.brokerage_percent&.to_f,
            promo: project.promo_live? ? { text: project.promo_text, ends_on: project.promo_ends_on } : nil,
            configurations: configuration_names(project),
            cover_photo_url: cover_photo_url(project),
            cover_thumb_url: cover_thumb_url(project),
            photo_count: photo_attachments(project).size,
            has_pin: project.has_pin?,
            pin_approximate: project.pin_approximate,
            created_at: project.created_at
          }
        end

        def detail(project)
          list(project).merge(
            rera_number: project.rera_number,
            address: project.address,
            lat: project.lat&.to_f,
            lng: project.lng&.to_f,
            pin_approximate: project.pin_approximate,
            google_place_id: project.google_place_id,
            typologies: project.project_typologies.map { |pt| typology(pt) },
            photos: photos(project),
            photo_urls: photo_urls(project),
            brochure_url: brochure_url(project),
            brokerage_ladder_url: project.brokerage_ladder.attached? ? BlobUrl.call(project.brokerage_ladder) : nil,
            on_website: project.on_website,
            slug: project.slug,
            website_url: website_url(project),
            external_ref: project.external_ref,
            rm_name: project.rm_name,
            rm_contact: project.rm_contact,
            shareable: shareable(project),
            portal_codes: project.portal_codes_payload,
            updated_at: project.updated_at
          )
        end

        # One row of typeahead results — what the row shows and nothing more.
        # The full project is one tap away at GET /projects/:id.
        #
        # `source` is `own` unless the caller passed include_marketplace, in
        # which case an active catalog row can appear as `catalog`. Mapping
        # that id links the marketplace row. A booking is what copies it.
        def search_hit(project)
          {
            id: project.id,
            code: project.code,
            name: project.name,
            rera_number: project.rera_number,
            source: project.source,
            builder: project.builder && { id: project.builder_id, name: project.builder.name },
            locality: project.locality&.name,
            locality_id: project.locality_id,
            city: project.city&.name,
            city_id: project.city_id,
            has_pin: project.has_pin?,
            match_label: Inventory::PossessionMatch.match_label(project)
          }
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
            configurations: configuration_names(project),
            promo_text: project.promo_live? ? project.promo_text : nil,
            photo_urls: photo_urls(project),
            brochure_url: brochure_url(project)
            # brokerage_percent and brokerage_ladder_url are deliberately absent:
            # what the broker earns is not the client's business.
          }
        end

        private

        # Never the Active Storage path. Share text and the firm site both
        # paste this, and a customer should not see /rails/active_storage.
        def brochure_url(project)
          Realtoriq::BrochureUrl.for(project)
        end

        def website_url(project)
          return nil unless project.on_website? && project.active? && project.from_own?
          return nil unless project.firm&.website_public?

          path = Sites::Host.listing_path("projects", project.code, project.name)
          path && Sites::Host.public_url(project.firm, path)
        end

        def typology(project_typology)
          {
            id: project_typology.id,
            typology_id: project_typology.typology_id,
            name: project_typology.typology&.name,
            label: project_typology.label,
            display_name: project_typology.display_name,
            category: project_typology.typology&.category,
            area: project_typology.area_payload,
            needs_review: project_typology.needs_review,
            starting_price: project_typology.starting_price,
            starting_carpet_sqft: project_typology.starting_carpet_sqft,
            rate_per_sqft: project_typology.rate_per_sqft
          }
        end

        def configuration_names(project)
          project.project_typologies.map { |row| row.typology&.name }.compact
        end

        def cover_photo_url(project)
          first = photo_attachments(project).first
          first && BlobUrl.call(first)
        end

        def cover_thumb_url(project)
          attachments = photo_attachments(project)
          attachments.each { |attachment| BlobUrl.prepare(attachment) }
          first = attachments.first
          first && BlobUrl.variant(first, :thumb)
        end

        # Attachment ids are random UUIDs, so sorting by id shuffles the gallery.
        # created_at is upload order. The first upload is the banner.
        def photo_attachments(project)
          project.photos.attachments.sort_by { |attachment| [ attachment.created_at, attachment.id ] }
        end

        # Carries the attachment id, which `photo_urls` does not — and without
        # it DELETE /projects/:id/photos/:photo_id was uncallable: the id
        # appeared in no response, and the signed blob URL encodes the *blob*
        # id, which is a different record. Detail only. `shareable` keeps the
        # bare urls, because an id is of no use to a client and share payloads
        # get pasted into WhatsApp.
        def photos(project)
          photo_attachments(project).map { |attachment| BlobUrl.photo(attachment) }
        end

        def photo_urls(project) = photo_attachments(project).map { |a| BlobUrl.call(a) }
      end
    end
  end
end
