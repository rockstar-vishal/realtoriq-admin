# frozen_string_literal: true

module Api
  module V1
    class ProjectsController < AuthenticatedController
      include AttachesPhotos

      before_action :set_project, only: %i[show update add_photos remove_photo]

      def index
        scope = filtered_scope
        @pagy, records = pagy(scope, limit: per_page)

        render json: {
          projects: records.map { |p| ProjectSerializer.list(p) },
          meta: pagination_meta(@pagy)
        }, status: :ok
      end

      def show
        render json: { project: ProjectSerializer.detail(@project) }, status: :ok
      end

      def create
        result = Inventory::CreateProject.new(
          firm: current_firm,
          attributes: project_params,
          typologies: params[:typologies],
          brochure_signed_id: params[:brochure_signed_id]
        ).call

        return render_validation_errors(result.errors) unless result.ok?

        render json: { project: ProjectSerializer.detail(result.project) }, status: :created
      end

      def update
        @project.assign_attributes(project_params)
        replace_typologies if params.key?(:typologies)
        attach_brochure if params.key?(:brochure_signed_id)

        return render_validation_errors(@project.errors) unless @project.save

        render json: { project: ProjectSerializer.detail(@project.reload) }, status: :ok
      end

      # Photos live on the detail screen rather than the create form — the
      # design says so explicitly, so they get their own endpoint.
      def add_photos
        attach_photos(@project, params[:photo_signed_ids] || params[:signed_ids]) do
          render json: { project: ProjectSerializer.detail(@project.reload) }, status: :created
        end
      end

      def remove_photo
        detach_photo(@project, params[:photo_id]) do
          render json: { project: ProjectSerializer.detail(@project.reload) }, status: :ok
        end
      end

      private

      def set_project
        @project = base_scope.find_by(id: params[:id])
        return if @project

        render_error("not_found", "Project not found", status: :not_found)
      end

      # Inventory is firm-wide: unlike leads, everyone in the firm sees it all.
      def base_scope
        Project.includes(:builder, :city, :locality, project_typologies: :typology)
      end

      def filtered_scope
        scope = base_scope
          .search(params[:q])
          .possession_before(params[:possession_before])
          .budget_between(params[:budget_min], params[:budget_max])
          .for_typologies(params[:typology_ids])

        scope = scope.where(builder_id: params[:builder_id]) if params[:builder_id].present?
        scope = scope.where(city_id: params[:city_id]) if params[:city_id].present?
        scope = scope.where(locality_id: params[:locality_id]) if params[:locality_id].present?
        scope = scope.where(status: params[:status].presence || "active")

        scope.alphabetical
      end

      def replace_typologies
        @project.project_typologies.destroy_all
        Array(params[:typologies]).each do |row|
          attrs = row.permit(:typology_id, :starting_price, :starting_carpet_sqft)
          @project.project_typologies.build(attrs)
        end
      end

      def attach_brochure
        signed_id = params[:brochure_signed_id]
        signed_id.present? ? @project.brochure.attach(signed_id) : @project.brochure.purge_later
      rescue ActiveSupport::MessageVerifier::InvalidSignature
        @project.errors.add(:brochure, "isn't a valid upload")
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

      def project_params
        params.permit(
          :name, :builder_id, :city_id, :locality_id, :address, :lat, :lng,
          :google_place_id, :starting_budget, :possession_on, :possession_label,
          :rera_number, :brokerage_percent, :promo_text, :promo_ends_on, :status
        )
      end
    end
  end
end
