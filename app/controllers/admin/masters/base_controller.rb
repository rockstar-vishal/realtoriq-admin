# frozen_string_literal: true

module Admin
  module Masters
    # The seven master tables are all the same shape: a list, an inline create
    # form, inline edit, and a delete that refuses when something depends on the
    # row. Rather than seven near-identical controllers, each subclass declares
    # its model, its columns and its permitted params.
    class BaseController < Admin::BaseController
      before_action :set_record, only: %i[edit update destroy]

      class_attribute :master_model, :master_columns, :master_permitted, :master_label

      # All seven masters render one template. Rails looks for a view under the
      # concrete controller's own directory by default, so it has to be named.
      SHARED_TEMPLATE = "admin/masters/index"

      def index
        @records = scope
        @record = master_model.new
        render SHARED_TEMPLATE
      end

      def new
        @records = scope
        @record = master_model.new
        render SHARED_TEMPLATE
      end

      def create
        @record = master_model.new(master_params)

        if @record.save
          redirect_to index_path, notice: "#{master_label} added."
        else
          @records = scope
          render SHARED_TEMPLATE, status: :unprocessable_content
        end
      end

      def edit
        @records = scope
        render SHARED_TEMPLATE
      end

      def update
        if @record.update(master_params)
          redirect_to index_path, notice: "#{master_label} updated."
        else
          @records = scope
          render SHARED_TEMPLATE, status: :unprocessable_content
        end
      end

      def destroy
        if @record.destroy
          redirect_to index_path, notice: "#{master_label} deleted."
        else
          # restrict_with_error, e.g. a city that still has localities.
          redirect_to index_path, alert: @record.errors.full_messages.to_sentence
        end
      end

      # Path building lives here rather than in a helper because only the
      # controller knows whether its records are addressed by :slug or :id.
      helper_method :master_index_path, :master_member_path, :master_edit_path, :master_columns

      def master_index_path = index_path

      def master_member_path(record)
        url_for(action: :update, finder_param => record.to_param, only_path: true)
      end

      def master_edit_path(record)
        url_for(action: :edit, finder_param => record.to_param, only_path: true)
      end

      private

      def scope = raise(NotImplementedError)

      def index_path = raise(NotImplementedError)

      def set_record
        @record = master_model.find_by!(finder_column => params[finder_param])
      end

      # Cities and builders are addressed by slug; the rest by id.
      def finder_column = :id

      def finder_param = :id

      def master_params
        params.expect(master_model.model_name.param_key.to_sym => master_permitted)
      end

      helper_method :master_label
    end
  end
end
