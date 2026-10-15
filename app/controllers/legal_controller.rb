# frozen_string_literal: true

class LegalController < Onboarding::BaseController
  def show
    @document = if params[:version].present?
      Legal::Registry.find(params[:kind], params[:version])
    else
      Legal::Registry.current(params[:kind])
    end
    @title = @document.kind == "terms" ? "Terms & Conditions" : "Privacy Policy"
    @html = Legal::HtmlRenderer.new(@document).render
    response.headers["Cache-Control"] = "public, max-age=300"
    render layout: "legal_embed" if params[:embed] == "1"
  end
end
