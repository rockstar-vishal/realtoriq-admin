# frozen_string_literal: true

module Realtoriq
  # Public PDF for a brochure this firm uploaded. No broker session: the
  # project code is the link. A marketplace brochure is not served here; that
  # file stays on LaunchIQ at /realtoriq/brochures/:code.
  class BrochuresController < ActionController::API
    def show
      project = Project.across_firms.find_by(code: params[:code].to_s.upcase)
      blob = project&.brochure&.blob
      return missing unless blob&.content_type == "application/pdf"

      send_pdf(blob.download, project)
    end

    private

    def send_pdf(bytes, project)
      send_data bytes, filename: download_name(project), type: "application/pdf", disposition: "inline"
      response.headers["Cache-Control"] = "no-store"
      response.headers["X-Content-Type-Options"] = "nosniff"
    end

    # The stored LaunchIQ name is a storage filename. The project name is
    # what the customer should see if they save the file.
    def download_name(project)
      base = project.name.to_s.strip.gsub(/[^\w.\-]+/, "-").gsub(/-+/, "-")
      base = base.delete_prefix("-").delete_suffix("-").sub(/\.pdf\z/i, "")
      base = "brochure" if base.blank?
      "#{base[0, 80]}.pdf"
    end

    def missing
      head :not_found
    end
  end
end
