# frozen_string_literal: true

module Admin
  module Firms
    # Ops release a Page another firm needs. The broker app cannot do this.
    class FacebookPagesController < Admin::BaseController
      before_action :set_firm

      def release
        page = @firm.facebook_pages.find(params[:id])
        name = page.page_name
        ::Facebook::ReleasePage.call(page:, actor: current_admin)
        redirect_to admin_firm_path(@firm), notice: "#{name} released. Another firm can connect it."
      end

      private

      def set_firm
        @firm = Firm.find_by!(slug: params[:firm_slug])
      end
    end
  end
end
