# frozen_string_literal: true

module Api
  module V1
    class ProjectsController < AuthenticatedController
      # `sort=name` (the default, so existing callers see no change) or
      # `sort=recent`, which puts a just-created project on page one instead of
      # wherever its name falls alphabetically. Unknown values fall back to the
      # default, in keeping with how the rest of the API treats stray params.
      #
      # `id` breaks ties in both. Postgres documents that rows with equal sort
      # keys come back in an unspecified order, so under LIMIT/OFFSET a page
      # boundary inside several same-named projects is permitted to repeat one
      # and skip another. Not observed here — small tables return ties stably —
      # but nothing guarantees it, and staging already has four called "Test".
      # Ids are UUIDv7, so the tiebreak is also creation order.
      SORTS = {
        "name" => -> { order(:name, :id) },
        "recent" => -> { order(created_at: :desc, id: :desc) }
      }.freeze
      DEFAULT_SORT = "name"

      # Drawer fields. `status` is a heading pill and must not drop `q`, or
      # My Projects search with status=active would never run.
      DRAWER_KEYS = %w[
        builder_id typology_ids budget_min budget_max city_id locality_id
        brokerage_min brokerage_max
      ].freeze

      include AttachesPhotos

      before_action :set_project, only: %i[show update add_photos remove_photo visitors]
      before_action :require_super_admin, only: %i[create update add_photos remove_photo]
      before_action :reject_catalog_mutation, only: %i[update add_photos remove_photo]

      def index
        scope = filtered_scope
        @pagy, records = pagy(scope, limit: per_page)

        render json: {
          projects: records.map { |p| ProjectSerializer.list(p) },
          meta: pagination_meta(@pagy)
        }, status: :ok
      end

      def search
        result = Inventory::ProjectSearch.new(query: params[:q]).call

        unless result.ok?
          return render_error(result.error_code, result.error_message,
                              status: :unprocessable_content, details: result.details)
        end

        render json: {
          projects: result.projects.map { |p| ProjectSerializer.search_hit(p) },
          meta: {
            query: result.query,
            limit: Inventory::ProjectSearch::LIMIT,
            min_length: Inventory::ProjectSearch::MIN_LENGTH,
            # More matches exist past the limit — the app can prompt to keep typing.
            more: result.more,
            # Nothing matched as typed, so these are close spellings instead —
            # the app can label them "did you mean".
            fuzzy: result.fuzzy
          }
        }, status: :ok
      end

      def show
        render json: { project: ProjectSerializer.detail(@project) }, status: :ok
      end

      def visitors
        render json: Inventory::VisitorList.new(site: @project, user: current_user, page: params[:page]).as_json,
               status: :ok
      end

      def create
        result = Inventory::CreateProject.new(
          firm: current_firm,
          attributes: project_params,
          typologies: params[:typologies],
          brochure_signed_id: params[:brochure_signed_id]
        ).call

        unless result.ok?
          if result.error_code
            return render_error(result.error_code, result.error_message, status: :unprocessable_content)
          end

          return render_validation_errors(result.errors)
        end

        render json: { project: ProjectSerializer.detail(result.project) }, status: :created
      end

      def update
        @project.assign_attributes(project_params)
        replace_typologies if params.key?(:typologies)

        # Accept (or decide to purge) *before* save, and only after the record
        # is valid. Attaching first used to purge the brochure on a rejected
        # PATCH — a failed validation destroyed the file.
        brochure_blob = nil
        if params.key?(:brochure_signed_id) && params[:brochure_signed_id].present?
          accepted = Uploads::AcceptSignedId.new(
            signed_id: params[:brochure_signed_id], firm: current_firm, purpose: "project_brochure"
          ).call
          unless accepted.ok?
            return render_error(accepted.error_code, accepted.error_message, status: :unprocessable_content)
          end

          brochure_blob = accepted.blob
        end

        return render_validation_errors(@project.errors) unless @project.valid?

        Project.transaction do
          @project.save!
          apply_brochure(brochure_blob) if params.key?(:brochure_signed_id)
        end

        render json: { project: ProjectSerializer.detail(@project.reload) }, status: :ok
      end

      # Photos live on the detail screen rather than the create form — the
      # design says so explicitly, so they get their own endpoint.
      def add_photos
        attach_photos(@project, params[:photo_signed_ids] || params[:signed_ids], purpose: "project_photo") do
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
        scope = base_scope.from_own
          .search(drawer_filters_present? ? nil : params[:q])
          .possession_before(params[:possession_before])
          .budget_between(params[:budget_min], params[:budget_max])
          .brokerage_between(params[:brokerage_min], params[:brokerage_max])
          .for_typologies(params[:typology_ids])

        scope = scope.where(builder_id: params[:builder_id]) if params[:builder_id].present?
        scope = scope.where(city_id: params[:city_id]) if params[:city_id].present?
        scope = scope.where(locality_id: params[:locality_id]) if params[:locality_id].present?
        scope = scope.where(status: params[:status].presence || "active") unless params[:status].to_s == "all"

        apply_sort(scope)
      end

      def drawer_filters_present?
        DRAWER_KEYS.any? { |key| params[key].present? }
      end

      def apply_sort(scope)
        scope.instance_exec(&SORTS.fetch(params[:sort].to_s, SORTS[DEFAULT_SORT]))
      end

      def reject_catalog_mutation
        return unless @project.from_catalog?

        render_error("catalog_readonly", "Catalog projects cannot be edited.",
                     status: :unprocessable_content)
      end

      def replace_typologies
        @project.project_typologies.destroy_all
        Array(params[:typologies]).each do |row|
          attrs = row.permit(:typology_id, :starting_price, :starting_carpet_sqft)
          @project.project_typologies.build(attrs)
        end
      end

      def apply_brochure(blob)
        blob.present? ? @project.brochure.attach(blob) : @project.brochure.purge_later
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
