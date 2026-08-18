# frozen_string_literal: true

module Api
  module V1
    class PropertiesController < AuthenticatedController
      include AttachesPhotos

      before_action :set_property, only: %i[show update add_photos remove_photo]

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

      def create
        property = Property.new(property_params)
        property.firm = current_firm

        return render_validation_errors(property.errors) unless property.save

        render json: { property: PropertySerializer.detail(property) }, status: :created
      end

      def update
        return render_validation_errors(@property.errors) unless @property.update(property_params)

        render json: { property: PropertySerializer.detail(@property.reload) }, status: :ok
      end

      def add_photos
        attach_photos(@property, params[:photo_signed_ids] || params[:signed_ids]) do
          render json: { property: PropertySerializer.detail(@property.reload) }, status: :created
        end
      end

      def remove_photo
        detach_photo(@property, params[:photo_id]) do
          render json: { property: PropertySerializer.detail(@property.reload) }, status: :ok
        end
      end

      private

      def set_property
        @property = base_scope.find_by(id: params[:id])
        return if @property

        render_error("not_found", "Property not found", status: :not_found)
      end

      def base_scope
        Property.includes(:typology, building: %i[city locality])
      end

      def filtered_scope
        scope = base_scope
          .search(params[:q])
          .price_between(params[:price_min], params[:price_max])
          .in_city(params[:city_id])
          .in_locality(params[:locality_id])

        scope = scope.where(listing_for: params[:listing_for]) if params[:listing_for].present?
        scope = scope.where(building_id: params[:building_id]) if params[:building_id].present?
        scope = scope.where(typology_id: params[:typology_id]) if params[:typology_id].present?
        scope = scope.where(floor_band: params[:floor_band]) if params[:floor_band].present?
        scope = scope.where(status: params[:status].presence || "available")

        scope.newest_first
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

      def property_params
        params.permit(:building_id, :typology_id, :listing_for, :floor_band, :price,
                      :carpet_area_sqft, :available_from, :description,
                      :confidential_note, :status)
      end
    end
  end
end
