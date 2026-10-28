# frozen_string_literal: true

require "rails_helper"

RSpec.describe OpsAlertMailer do
  def line(n)
    { at: "28 Oct, 11:0#{n} AM", job_class: "ExampleJob", error_class: "RuntimeError", message: "made up #{n}" }
  end

  def mail_for(count)
    described_class.failed_jobs(to: "ops@example.com", lines: count.times.map { |n| line(n) }, more: 0, total: count)
  end

  it "says one failed job is waiting" do
    body = mail_for(1).text_part.body.decoded

    expect(body).to include("1 failed job is waiting in total")
    expect(body).not_to include("1 failed jobs")
  end

  it "says three failed jobs are waiting" do
    expect(mail_for(3).text_part.body.decoded).to include("3 failed jobs are waiting in total")
  end

  it "is multipart and both parts contain both commands" do
    mail = mail_for(1)

    expect(mail).to be_multipart
    [ mail.text_part, mail.html_part ].each do |part|
      decoded = CGI.unescapeHTML(part.body.decoded)
      expect(decoded).to include(Ops::FailedJobCommands::LOOK)
      expect(decoded).to include(Ops::FailedJobCommands::RETRY_OR_DISCARD)
    end
    expect(Ops::FailedJobCommands::LOOK).not_to match(/\b[a-z_]+\.(id|app|dev|io|co|in)\b/)
    expect(Ops::FailedJobCommands::RETRY_OR_DISCARD).not_to match(/\b[a-z_]+\.(id|app|dev|io|co|in)\b/)
  end
end
