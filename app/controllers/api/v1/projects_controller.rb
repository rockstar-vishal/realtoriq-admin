# frozen_string_literal: true

module Api
  module V1
    class ProjectsController < AuthenticatedController
      # `sort=name` (the default, so existing callers see no change) or
      # `sort=recent`, which puts a just-created project on page one instead of
      # wherever its name falls alphabetically. `sort=relevant` is handled in
      # `apply_sort` — it is not a static order. Unknown values fall back to
      # the default, in keeping with how the rest of the API treats stray params.
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
      # `name` is the advanced-search project name. It drops `q`, like every
      # other drawer field, and is applied on its own so a name plus a city
      # still filters by both.
      DRAWER_KEYS = %w[
        name builder_id typology_ids budget_min budget_max city_id locality_id
        brokerage_min brokerage_max
      ].freeze

      include AttachesPhotos

      before_action :set_project, only: %i[
        show update add_photos remove_photo visitors share_link lead_matches marketplace_leads mapped_customers
        portal_codes
      ]
      before_action :require_super_admin, only: %i[create update add_photos remove_photo portal_codes]
      before_action :reject_catalog_mutation, only: %i[update add_photos remove_photo portal_codes]

      def index
        scope = filtered_scope
        @pagy, records = pagy(scope, limit: per_page)

        render json: {
          projects: records.map { |p| ProjectSerializer.list(p) },
          meta: pagination_meta(@pagy)
        }, status: :ok
      end

      def search
        result = Inventory::ProjectSearch.new(
          query: params[:q], status: params[:status], include_marketplace: params[:include_marketplace]
        ).call

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

      def lead_matches
        render json: {
          matches: Inventory::MatchLeads.new(project: @project, user: current_user).call
        }, status: :ok
      end

      def mapped_customers
        render json: Inventory::MappedCustomers.new(site: @project, user: current_user, page: params[:page]).as_json,
               status: :ok
      end

      def marketplace_leads
        unless @project.marketplace? || @project.external_ref.to_s.match?(/\APR[0-9A-F]+\z/i)
          return render_error("not_marketplace", "Only a marketplace project has leads from the microsite.",
                              status: :unprocessable_content)
        end

        result = Realtoriq::ProjectLeads.new(project: @project, user: current_user).call(page: params[:page])
        render json: {
          leads: result.leads,
          meta: {
            page: result.page,
            per_page: result.per_page,
            total_count: result.total_count,
            total_pages: result.total_pages
          }
        }, status: :ok
      end

      def share_link
        target = marketplace_share_target
        if target.nil?
          return render_error("not_marketplace", "Only a marketplace project can be shared as a microsite.",
                              status: :unprocessable_content)
        end

        origin = Realtoriq::Credentials.turbo_public_origin
        if origin.blank?
          return render_error("turbo_origin_missing",
                              "Set realtoriq.turbo_public_origin before sharing a microsite.",
                              status: :service_unavailable)
        end

        link = ProjectShareLink.create_or_find_by!(project: target, user: current_user) do |row|
          row.firm = current_user.firm
        end
        url = "#{origin}/m/#{target.external_ref}?share_token=#{link.token}"
        render json: { share_link: { url: url, token: link.token } }, status: :ok
      end

      def create
        result = Inventory::CreateProject.new(
          firm: current_firm,
          attributes: project_params,
          typologies: params[:typologies],
          brochure_signed_id: params[:brochure_signed_id],
          brokerage_ladder_signed_id: params[:brokerage_ladder_signed_id]
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
        # Accept the brochure *before* the save transaction. Attaching first
        # used to purge the brochure on a rejected PATCH.
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

        ladder_blob = nil
        if params.key?(:brokerage_ladder_signed_id) && params[:brokerage_ladder_signed_id].present?
          accepted = Uploads::AcceptSignedId.new(
            signed_id: params[:brokerage_ladder_signed_id], firm: current_firm,
            purpose: "project_brokerage_ladder"
          ).call
          unless accepted.ok?
            return render_error(accepted.error_code, accepted.error_message, status: :unprocessable_content)
          end

          ladder_blob = accepted.blob
        end

        saved = false
        Project.transaction do
          @project.assign_attributes(project_params)
          replace_typologies if params.key?(:typologies)
          Inventory::ProjectMatchFields.apply(@project)
          saved = @project.errors.empty? && @project.save
          raise ActiveRecord::Rollback unless saved

          apply_brochure(brochure_blob) if params.key?(:brochure_signed_id)
          apply_brokerage_ladder(ladder_blob) if params.key?(:brokerage_ladder_signed_id)
        end

        return render_validation_errors(@project.errors) unless saved

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

      def portal_codes
        @project.assign_portal_codes(portal_code_params)
        render json: { project: ProjectSerializer.detail(@project.reload) }, status: :ok
      rescue ActiveRecord::RecordNotUnique
        render_error("invalid", "That portal code is already saved on another project.",
          status: :unprocessable_content)
      end

      private

      def set_project
        @project = base_scope.find_by(id: params[:id])
        @project ||= Project.marketplace
          .includes(:builder, :city, :locality, project_typologies: :typology)
          .with_attached_photos
          .find_by(id: params[:id])
        return if @project

        render_error("not_found", "Project not found", status: :not_found)
      end

      # Inventory is firm-wide: unlike leads, everyone in the firm sees it all.
      def base_scope
        Project.includes(:builder, :city, :locality, project_typologies: :typology).with_attached_photos
      end

      def filtered_scope
        scope = if params[:source].to_s == "catalog"
          Project.marketplace.includes(:builder, :city, :locality, project_typologies: :typology).with_attached_photos
        else
          base_scope.from_own
        end

        scope = scope
          .search(drawer_filters_present? ? nil : params[:q])
          .named_like(params[:name])
          .possession_before(params[:possession_before])
          .budget_between(params[:budget_min], params[:budget_max])
          .brokerage_between(params[:brokerage_min], params[:brokerage_max])
          .for_typologies(params[:typology_ids])

        scope = scope.where(builder_id: params[:builder_id]) if params[:builder_id].present?
        scope = scope.where(city_id: params[:city_id]) if params[:city_id].present?
        scope = scope.where(locality_id: params[:locality_id]) if params[:locality_id].present?
        unless params[:source].to_s == "catalog" || params[:status].to_s == "all"
          scope = scope.where(status: params[:status].presence || "active")
        end

        apply_sort(scope)
      end

      def drawer_filters_present?
        DRAWER_KEYS.any? { |key| params[key].present? }
      end

      # `sort=relevant` is the marketplace browse order. It uses the signed-in
      # firm's localities, never a locality id from the query. Search stays
      # A–Z, a filtered marketplace list stays newest first, and My Projects
      # keeps the sort it was given (or A–Z).
      def apply_sort(scope)
        return scope.relevant_to(Current.firm) if relevant_catalog_sort?

        scope.instance_exec(&SORTS.fetch(sort_key, SORTS[DEFAULT_SORT]))
      end

      def relevant_catalog_sort?
        sort_param == "relevant" &&
          params[:source].to_s == "catalog" &&
          params[:q].blank? &&
          !drawer_filters_present?
      end

      def sort_key
        return sort_param unless sort_param == "relevant" && !relevant_catalog_sort?

        if params[:source].to_s == "catalog" && drawer_filters_present? && params[:q].blank?
          "recent"
        else
          DEFAULT_SORT
        end
      end

      def sort_param
        params[:sort].is_a?(String) ? params[:sort] : ""
      end

      # The microsite belongs to the global catalog row. A broker opening the
      # firm's copy still shares that microsite, looked up by the project code.
      def marketplace_share_target
        return @project if @project.marketplace?
        return unless @project.external_ref.to_s.match?(/\APR[0-9A-F]+\z/i)

        Project.marketplace.find_by(external_ref: @project.external_ref)
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

      def apply_brokerage_ladder(blob)
        blob.present? ? @project.brokerage_ladder.attach(blob) : @project.brokerage_ladder.purge_later
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

      def portal_code_params
        params.permit("99acres", "magicbricks", "housing").to_h
      end
    end
  end
end
