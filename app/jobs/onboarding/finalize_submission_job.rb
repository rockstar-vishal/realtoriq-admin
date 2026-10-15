# frozen_string_literal: true

module Onboarding
  # Attaches the acceptance PDF and emails it to the broker. Running it again
  # does not attach a second file or send a second email.
  class FinalizeSubmissionJob < ApplicationJob
    queue_as :default

    retry_on StandardError, wait: :polynomially_longer, attempts: 5
    discard_on ActiveRecord::RecordNotFound

    def perform(acceptance_id)
      acceptance = LegalAcceptance.across_firms.find(acceptance_id)
      application = OnboardingApplication.across_firms.find(acceptance.onboarding_application_id)
      previous = Current.firm
      Current.firm = application.firm

      attach_pdf(acceptance, application) unless acceptance.document.attached?
      return if acceptance.emailed_at.present?

      OnboardingMailer.registration_received(application.id).deliver_now
      acceptance.update!(emailed_at: Time.current)
    ensure
      Current.firm = previous
    end

    private

    def attach_pdf(acceptance, application)
      bytes = Legal::AcceptancePdf.new(acceptance, application).render
      acceptance.document.attach(
        io: StringIO.new(bytes),
        filename: "RealtorIQ-Terms-#{application.reference}.pdf",
        content_type: "application/pdf"
      )
      acceptance.update!(
        pdf_sha256: Digest::SHA256.hexdigest(bytes),
        pdf_generated_at: Time.current
      )
    end
  end
end
