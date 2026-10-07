# frozen_string_literal: true

module Api
  module V1
    module Facebook
      class PagesController < BaseController
        before_action :set_page

        def subscribe
          client = ::Facebook::GraphApiClient.new(access_token: @page.page_access_token)
          ok = client.subscribed_apps(@page.page_id)
          unless ok
            return render_error("facebook_error", "Could not subscribe this Page.", status: :unprocessable_entity)
          end

          @page.subscribe!
          render json: { page: page_json }
        rescue ::Facebook::Errors::Base => e
          ::Facebook::TokenManager.handle_api_error(@page.facebook_connection, e, page: @page)
          render_error("facebook_error", "Could not subscribe this Page.", status: :unprocessable_entity)
        rescue Koala::Facebook::APIError, Faraday::Error
          render_error("facebook_error", "Could not subscribe this Page.", status: :unprocessable_entity)
        end

        def unsubscribe
          if @page.page_access_token.present?
            ::Facebook::GraphApiClient.new(access_token: @page.page_access_token).unsubscribe_page(@page.page_id)
          end

          @page.unsubscribe!
          render json: { page: page_json }
        rescue ::Facebook::Errors::Base => e
          ::Facebook::TokenManager.handle_api_error(@page.facebook_connection, e, page: @page)
          render_error("facebook_error", "Could not unsubscribe this Page.", status: :unprocessable_entity)
        rescue Koala::Facebook::APIError, Faraday::Error
          render_error("facebook_error", "Could not unsubscribe this Page.", status: :unprocessable_entity)
        end

        def sync_forms
          result = ::Facebook::FormSyncer.sync_page!(@page)
          if result.success?
            render json: {
              forms_count: result.forms_count,
              mapped: result.mapped,
              available: result.available
            }
          else
            render_error("facebook_error", "Could not sync forms.", status: :unprocessable_entity)
          end
        end

        private

        def set_page
          @page = current_firm.facebook_pages.find_by(id: params[:id])
          not_found if @page.nil?
        end

        def page_json
          {
            "id" => @page.id,
            "page_id" => @page.page_id,
            "page_name" => @page.page_name,
            "status" => @page.status,
            "subscribed" => @page.subscribed?,
            "status_message" => @page.status_message
          }
        end
      end
    end
  end
end
