# frozen_string_literal: true

module Api
  module V1
    # Firm-owned buildings. The design creates these inline from the property
    # form — "Building not listed? Add new" — so create has to be cheap and the
    # response has to carry enough for the client to select it straight away.
    class BuildingsController < AuthenticatedController
      before_action :set_building, only: %i[update]

      def index
        scope = Building.includes(:city, :locality).search(params[:q])
        scope = scope.where(city_id: params[:city_id]) if params[:city_id].present?
        scope = scope.where(locality_id: params[:locality_id]) if params[:locality_id].present?

        @pagy, records = pagy(scope.alphabetical, limit: 50)

        render json: {
          buildings: records.map { |b| BuildingSerializer.call(b) },
          meta: pagination_meta(@pagy)
        }, status: :ok
      end

      def create
        building = Building.new(building_params)
        building.firm = current_firm

        unless building.save
          return render_error("invalid", building.errors.full_messages.to_sentence,
                              status: :unprocessable_content, details: building.errors.to_hash)
        end

        render json: { building: BuildingSerializer.call(building) }, status: :created
      end

      def update
        unless @building.update(building_params)
          return render_error("invalid", @building.errors.full_messages.to_sentence,
                              status: :unprocessable_content, details: @building.errors.to_hash)
        end

        render json: { building: BuildingSerializer.call(@building) }, status: :ok
      end

      private

      def set_building
        @building = Building.find_by(id: params[:id])
        return if @building

        render_error("not_found", "Building not found", status: :not_found)
      end

      def building_params
        params.permit(:name, :city_id, :locality_id, :address, :lat, :lng,
                      :google_place_id, :has_pool, :has_gym)
      end
    end
  end
end
