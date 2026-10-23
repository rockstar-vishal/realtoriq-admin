# frozen_string_literal: true

module Api
  module V1
    class PropertiesController < AuthenticatedController
      # `sort=recent` (the default — properties were already newest first, and
      # that stays unchanged) or `sort=name`. A property has no name of its
      # own; brokers know a listing by its building, so `name` means building
      # name. `id` breaks ties for the same reason as in ProjectsController —
      # several flats share a building, and without it pagination is unstable.
      SORTS = {
        "recent" => -> { order(created_at: :desc, id: :desc) },
        "name" => -> { order("properties.building_name ASC", :id) }
      }.freeze
      DEFAULT_SORT = "recent"

      # Drawer fields. `status` is a heading pill and must not drop `q`.
      DRAWER_KEYS = %w[
        city_id locality_id typology_id price_min price_max carpet_min carpet_max
        listing_for
      ].freeze

      include AttachesPhotos

      before_action :set_property, only: %i[show update add_photos remove_photo visitors lead_matches mapped_customers portal_codes]

      def index
        @pagy, records = pagy(filtered_scope, limit: per_page)

        render json: {
          # list never carries confidential_note — see PropertySerializer.
          properties: records.map { |p| PropertySerializer.list(p) },
          meta: pagination_meta(@pagy)
        }, status: :ok
      end

      def show
        render json: { property: PropertySerializer.detail(@property) }, status: :ok
      end

      def visitors
        render json: Inventory::VisitorList.new(site: @property, user: current_user, page: params[:page]).as_json,
               status: :ok
      end

      def lead_matches
        owner = @property.firm_id == current_firm.id
        render json: {
          matches: Inventory::MatchLeads.new(property: @property, user: current_user).call,
          marketplace_matches: owner ? Inventory::MarketplaceLeadMatches.new(property: @property).call : [],
          marketplace_firms: owner ? Inventory::MarketplaceFirms.new(property: @property).call : []
        }, status: :ok
      end

      # Every other active firm's shared, available listing. Safe cards only.
      def marketplace_index
        scope = Inventory::MarketplaceListings.new(query: params[:q]).scope
        @pagy, records = pagy(scope, limit: per_page)
        channels = ContactChannel.unscoped
          .where(firm_id: records.map(&:firm_id), kind: %w[mobile whatsapp])
          .group_by(&:firm_id)

        render json: {
          properties: records.map { |property|
            PropertySerializer.marketplace_list(property, channels[property.firm_id] || [])
          },
          meta: pagination_meta(@pagy)
        }, status: :ok
      end

      # Another firm's view of a shared listing. The owning firm uses #show.
      def marketplace
        property = Property.unscoped.includes(:typology, :firm, :city, :locality).find_by(id: params[:id])
        return render_error("not_found", "Property not found", status: :not_found) unless shared_listing_for_caller?(property)

        render json: { property: PropertySerializer.marketplace(property) }, status: :ok
      end

      def mapped_customers
        render json: Inventory::MappedCustomers.new(site: @property, user: current_user, page: params[:page]).as_json,
               status: :ok
      end

      def create
        property = Property.new(property_params)
        property.firm = current_firm
        property.created_by_user = current_user

        return render_validation_errors(property.errors) unless property.save(context: [ :create, :listing_form ])

        render json: { property: PropertySerializer.detail(property) }, status: :created
      end

      def update
        @property.assign_attributes(property_params)
        return render_validation_errors(@property.errors) unless @property.save(context: [ :update, :listing_form ])

        render json: { property: PropertySerializer.detail(@property.reload) }, status: :ok
      end

      def add_photos
        attach_photos(@property, params[:photo_signed_ids] || params[:signed_ids], purpose: "property_photo") do
          render json: { property: PropertySerializer.detail(@property.reload) }, status: :created
        end
      end

      def remove_photo
        detach_photo(@property, params[:photo_id]) do
          render json: { property: PropertySerializer.detail(@property.reload) }, status: :ok
        end
      end

      def portal_codes
        @property.assign_portal_codes(portal_code_params)
        render json: { property: PropertySerializer.detail(@property.reload) }, status: :ok
      rescue ActiveRecord::RecordNotUnique
        render_error("invalid", "That portal code is already saved on another property.",
          status: :unprocessable_content)
      end

      private

      def set_property
        @property = base_scope.find_by(id: params[:id])
        return if @property
        return if action_name == "lead_matches" && assign_shared_listing

        render_error("not_found", "Property not found", status: :not_found)
      end

      # A shared listing belongs to another firm. Exploring matches still scores
      # only this caller's own leads.
      def assign_shared_listing
        record = Property.unscoped.includes(:typology, :city, :locality).find_by(id: params[:id])
        return false unless shared_listing_for_caller?(record)

        @property = record
        true
      end

      # The owner must still be allowed to share, and the review demo is
      # neither a viewer nor a source.
      def shared_listing_for_caller?(record)
        return false unless record&.listed_on_marketplace? && record.available?
        return false if record.firm_id == current_firm.id || current_firm.review_demo?

        Firm.marketplace_eligible.exists?(id: record.firm_id)
      end

      def base_scope
        Property.includes(:typology, :created_by_user, :city, :locality)
      end

      def filtered_scope
        scope = base_scope
          .search(drawer_filters_present? ? nil : params[:q])
          .price_between(params[:price_min], params[:price_max])
          .carpet_between(params[:area_min].presence || params[:carpet_min], params[:area_max].presence || params[:carpet_max])
          .in_city(params[:city_id])
          .in_locality(params[:locality_id])

        scope = scope.where(listing_for: params[:listing_for]) if params[:listing_for].present?
        scope = scope.where(typology_id: params[:typology_id]) if params[:typology_id].present?
        if Typology::CATEGORIES.include?(params[:category].to_s)
          scope = scope.joins(:typology).where(typologies: { category: params[:category] })
        end
        scope = scope.where(floor_band: params[:floor_band]) if params[:floor_band].present?
        # `all` is the list chip; omitting status still means available, which is
        # what every existing caller that does not send the param expects.
        scope = scope.where(status: params[:status].presence || "available") unless params[:status].to_s == "all"

        apply_sort(scope)
      end

      def drawer_filters_present?
        DRAWER_KEYS.any? { |key| params[key].present? }
      end

      def apply_sort(scope)
        scope.instance_exec(&SORTS.fetch(params[:sort].to_s, SORTS[DEFAULT_SORT]))
      end

      def render_validation_errors(errors)
        render_error("invalid", errors.full_messages.to_sentence,
                     status: :unprocessable_content, details: errors.to_hash)
      end

      def per_page
        requested = params[:per_page].to_i
        return 25 if requested <= 0

        requested.clamp(1, 50)
      end

      LOCATION_KEYS = %i[
        building_name city_id locality_id address lat lng google_place_id has_pool has_gym
      ].freeze

      def property_params
        permitted = params.permit(:building_id, *LOCATION_KEYS, :typology_id, :listing_for, :floor_band, :price,
                      :carpet_area_sqft, :area_value, :area_unit, :pre_leased,
                      :available_from, :description,
                      :confidential_note, :status, :listed_on_marketplace, :on_website)
        # DetailSpecs keeps known keys and drops the rest, so the hash is not
        # a list of column names the client is allowed to set.
        permitted[:details] = params[:details].to_unsafe_h if params[:details].respond_to?(:to_unsafe_h)
        fill_location_from_building(permitted)
      end

      # Remove in the location cleanup
      def fill_location_from_building(permitted)
        return permitted if LOCATION_KEYS.any? { |key| params.key?(key) }
        return permitted if permitted[:building_id].blank?

        building = Building.find_by(id: permitted[:building_id])
        return permitted if building.nil?

        permitted[:building_name] = building.name
        permitted[:city_id] = building.city_id
        permitted[:locality_id] = building.locality_id
        permitted[:address] = building.address
        permitted[:lat] = building.lat
        permitted[:lng] = building.lng
        permitted[:google_place_id] = building.google_place_id
        permitted[:has_pool] = building.has_pool
        permitted[:has_gym] = building.has_gym
        permitted
      end

      def portal_code_params
        params.permit("99acres", "magicbricks", "housing").to_h
      end
    end
  end
end
