# frozen_string_literal: true

class FacebookAlertMailer < ApplicationMailer
  def token_invalid(user:, connection:)
    @connection = connection
    @settings_url = settings_url
    mail(to: user.email, subject: "Reconnect Facebook to keep receiving leads")
  end

  def page_needs_attention(user:, page:)
    @page = page
    @settings_url = settings_url
    mail(to: user.email, subject: "A Facebook Page needs attention")
  end

  def lead_import_failures(user:, imports:)
    @count = Array(imports).size
    @reasons = self.class.reason_summary(imports)
    @settings_url = settings_url
    mail(to: user.email, subject: "Facebook leads need attention")
  end

  def self.reason_summary(imports)
    Array(imports).group_by { |import| reason_text(import) }
      .map { |message, rows| { message:, count: rows.size } }
      .sort_by { |row| [ -row[:count], row[:message] ] }
      .first(3)
  end

  def self.reason_text(import)
    message = import.error_message.to_s.truncate(300).presence || "Could not import this lead"
    attempts = import.error_details.to_h["retry_count_at_failure"].to_i
    attempts >= FacebookLeadImport::MAX_RETRIES ? "#{message} after 5 attempts" : message
  end

  private

  def settings_url
    "#{Facebook::Credentials.web_origin}/settings/facebook"
  rescue Facebook::Errors::ConfigurationError
    "/settings/facebook"
  end
end
