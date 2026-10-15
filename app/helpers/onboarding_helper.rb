# frozen_string_literal: true

module OnboardingHelper
  # The labels the broker sees, so an error reads "Office address is required"
  # rather than "Address line1 is required", built from a column name.
  FIELD_LABELS = {
    applicant_name: "Your full name",
    applicant_designation: "Designation",
    firm_name: "Firm name",
    legal_name: "Legal name",
    entity_type: "Type of business",
    mobile: "Mobile number",
    whatsapp: "WhatsApp number",
    email: "Email address",
    address_line1: "Office address",
    address_line2: "Address line 2",
    city_id: "City",
    locality_id: "Office locality",
    pincode: "Pincode",
    extra_locality_ids: "Other localities",
    team_size: "Team size",
    pan: "PAN",
    gst: "GSTIN",
    rera_registered: "RERA registration",
    rera_number: "RERA registration number",
    rera_valid_till: "Valid till date",
    rera_certificate: "RERA certificate",
    rera_declaration: "RERA declaration",
    visiting_card: "Visiting card",
    accept: "Acceptance"
  }.freeze

  # Where each error in the summary jumps to. Anything not listed uses its
  # field id, which matches the input.
  FIELD_ANCHORS = {
    entity_type: "field-entity_type",
    mobile: "contact-mobile",
    whatsapp: "contact-whatsapp",
    email: "contact-email",
    city_id: "field-city_id",
    locality_id: "field-locality_id",
    extra_locality_ids: "field-extra_locality_ids",
    team_size: "field-team_size",
    rera_registered: "field-rera_registered",
    rera_declaration: "field-rera_declaration",
    rera_certificate: "field-rera_certificate",
    visiting_card: "field-visiting_card",
    accept: "field-accept"
  }.freeze

  # "is required" gets the label in front; a message that is already a
  # sentence ("This number is already registered…") is shown as it is.
  def signup_error_message(field, message)
    text = message.to_s
    if text.match?(/\A(is|isn't|must|does|are)\b/)
      "#{FIELD_LABELS.fetch(field.to_sym, field.to_s.humanize)} #{text}"
    else
      text.upcase_first
    end
  end

  def field_error(form, field)
    messages = form.errors[field]
    return if messages.blank?

    text = messages.map { |message| signup_error_message(field, message) }.uniq.to_sentence
    tag.p(text, class: "su-error", id: "#{field}_error")
  end

  def field_invalid(form, field)
    form.errors[field].present? ? "true" : nil
  end

  # [[message, "#anchor"], ...] for the summary at the top of a refused form.
  def signup_error_summary(form)
    form.errors.attribute_names.flat_map do |field|
      form.errors[field].map do |message|
        anchor = field == :base ? nil : "##{FIELD_ANCHORS[field] || field}"
        [ signup_error_message(field, message), anchor ]
      end
    end.uniq
  end

  # The form shows ten digits beside a fixed +91.
  def signup_phone_digits(value)
    value.to_s.delete_prefix("+91")
  end

  def signup_contact_display(kind, value)
    return value.to_s if kind.to_s == "email"

    digits = signup_phone_digits(value)
    digits.match?(/\A\d{10}\z/) ? "+91 #{digits[0, 5]} #{digits[5, 5]}" : value.to_s
  end

  def ist_stamp(time)
    return "—" if time.blank?

    time.in_time_zone("Asia/Kolkata").strftime("%-d %b %Y, %H:%M IST")
  end
end
