# frozen_string_literal: true

# Registration mail. Arguments are ids: a FirmScoped record cannot ride along
# on GlobalID once the tenant is unset.
class OnboardingMailer < ApplicationMailer
  default reply_to: ENV.fetch("ONBOARDING_OPS_EMAIL", "realtoriq@kgen.tech")

  after_action :clear_tenant

  def registration_received(application_id)
    load_application(application_id)
    acceptance = LegalAcceptance.across_firms.find_by!(onboarding_application_id: @application.id)
    attachments[acceptance.document.filename.to_s] = acceptance.document.download
    mail(
      to: @application.email,
      subject: "Your RealtorIQ registration is successful (Ref #{@application.reference})"
    )
  end

  def new_application(application_id)
    load_application(application_id)
    @url = admin_application_url(@application.reference)
    mail(
      to: ops_email,
      subject: "New RealtorIQ application: #{@application.firm_name}, #{@application.city.name}"
    )
  end

  def approved(application_id)
    load_application(application_id)
    @subscription = @application.firm.current_subscription
    @mobile = Phone.mask(@application.mobile)
    mail(to: @application.email, subject: "Your RealtorIQ workspace is ready")
  end

  def rejected(application_id)
    load_application(application_id)
    mail(to: @application.email, subject: "Your RealtorIQ application was not accepted (Ref #{@application.reference})")
  end

  def otp_cap_reached(count, cap)
    @count = count
    @cap = cap
    mail(to: ops_email, subject: "RealtorIQ verification is at its hourly cap")
  end

  private

  def load_application(id)
    @application = OnboardingApplication.across_firms.find(id)
    Current.firm = @application.firm
  end

  def ops_email
    ENV.fetch("ONBOARDING_OPS_EMAIL", "realtoriq@kgen.tech")
  end

  def clear_tenant
    Current.firm = nil
  end
end
