# frozen_string_literal: true

module AdminSignIn
  def sign_in_admin(admin = nil)
    admin ||= create(:admin_user)
    post admin_session_path, params: { email: admin.email, password: "correct-horse-battery" }
    admin
  end
end

RSpec.configure do |config|
  config.include AdminSignIn, type: :request
end
