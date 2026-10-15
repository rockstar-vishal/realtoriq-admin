# frozen_string_literal: true

module Onboarding
  class ApplicationsController < BaseController
    def show
      @form = RegistrationForm.new
      @form.mobile = sitting.value(:mobile)
      @form.whatsapp = sitting.value(:whatsapp)
      @form.email = sitting.value(:email)
      # sync! clears a tick whose value does not match. Fill the contacts first,
      # or a blank form looks like the broker changed them.
      sitting.sync!(mobile: @form.mobile, email: @form.email, whatsapp: @form.whatsapp)
      load_choices
    end

    def submit
      @form = RegistrationForm.from_params(params)
      result = Submit.new(form: @form, sitting:, request:).call
      if result.ok
        sitting.clear!
        session[:registration_reference] = result.application.reference
        redirect_to registration_submitted_path
      else
        @files_again = true
        load_choices
        render :show, status: :unprocessable_content
      end
    end

    def submitted
      @reference = session[:registration_reference]
      redirect_to registration_path if @reference.blank?
    end

    def localities
      city = City.find_by(id: params[:city_id])
      rows = city ? city.localities.active.alphabetical : Locality.none
      render json: rows.map { |locality| { id: locality.id, name: locality.name } }
    end
  end
end
