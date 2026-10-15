# frozen_string_literal: true

module RegistrationExamples
  TINY_PNG = Base64.decode64("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==")

  def upload_bytes(bytes, name:, type:)
    file = Tempfile.new([ "upload", File.extname(name) ])
    file.binmode
    file.write(bytes)
    file.rewind
    Rack::Test::UploadedFile.new(file.path, type, original_filename: name)
  end

  def tiny_png(name = "card.png")
    upload_bytes(TINY_PNG, name:, type: "image/png")
  end

  def verify_registration_contact(kind, value)
    post registration_send_code_path(kind:), params: { kind => value }
    expect(response).to have_http_status(:ok)
    code = deliverer.deliveries.reverse.find { |delivery| delivery.destination == Phone.normalise(value) || delivery.destination == value.to_s.downcase }&.code
    code ||= deliverer.last.code
    post registration_verify_code_path(kind:), params: { kind => value, "#{kind}_code" => code }
    expect(response).to have_http_status(:ok)
  end

  def registration_fields(city:, locality:, **overrides)
    {
      applicant_name: "Asha Kulkarni",
      applicant_designation: "Partner",
      entity_type: "partnership",
      firm_name: "Kulkarni Estates",
      legal_name: "Kulkarni Estates",
      mobile: "9876543210",
      whatsapp: "9876543211",
      email: "asha@example.com",
      address_line1: "12 MG Road",
      city_id: city.id,
      locality_id: locality.id,
      pincode: "411001",
      rera_registered: "false",
      rera_declaration: "1",
      accept: "1",
      "g-recaptcha-response": "pass",
      visiting_card: tiny_png
    }.merge(overrides)
  end
end

RSpec.configure do |config|
  config.include RegistrationExamples, type: :request
end
