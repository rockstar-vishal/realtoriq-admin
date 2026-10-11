# frozen_string_literal: true

class WebsiteContactMailer < ApplicationMailer
  def message_received(to:, firm_name:, sender_name:, sender_mobile:, body:)
    @firm_name = one_line(firm_name).presence || "your firm"
    @sender_name = one_line(sender_name).presence || "A client"
    @sender_mobile = one_line(sender_mobile)
    @body = body.to_s.delete("\u0000")

    mail(to: one_line(to), subject: "Message from your website")
  end

  private

  def one_line(value)
    value.to_s.delete("\u0000").tr("\r\n", " ").strip
  end
end
