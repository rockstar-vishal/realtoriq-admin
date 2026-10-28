# frozen_string_literal: true

class OpsAlertMailer < ApplicationMailer
  def failed_jobs(to:, lines:, more:, total:)
    @lines = lines
    @more = more
    @total = total
    @look = Ops::FailedJobCommands::LOOK
    @retry_or_discard = Ops::FailedJobCommands::RETRY_OR_DISCARD
    @waiting_line = total == 1 ? "1 failed job is waiting in total" : "#{total} failed jobs are waiting in total"
    mail(to:, subject: self.class.subject_for(lines.size + more))
  end

  def self.subject_for(count)
    noun = count == 1 ? "1 Background Job Failed" : "#{count} Background Jobs Failed"
    "RealtorIQ: #{noun}"
  end
end
