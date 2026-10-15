# frozen_string_literal: true

module Onboarding
  # Public HTML, not the JSON API and not the admin panel. ActionController::Base
  # on purpose: ApplicationController's modern-browser gate would 406 old Android.
  class BaseController < ActionController::Base
    protect_from_forgery with: :exception
    layout "onboarding"

    before_action :mark_noindex
    before_action :limit_plain_posts

    private

    def mark_noindex
      response.headers["X-Robots-Tag"] = "noindex"
    end

    # Verification posts are small. Submit is multipart and is capped earlier,
    # by Onboarding::SubmitLimit, at 5 MB.
    def limit_plain_posts
      return unless request.post?
      return if request.media_type == "multipart/form-data"
      return if Sites::Throttle.body_ok?(request)

      head :content_too_large
    end

    def sitting
      @sitting ||= Sitting.new(cookies)
    end

    def load_choices
      @cities = City.active.alphabetical
      @localities = Locality.active.includes(:city).alphabetical
    end
  end
end
