# frozen_string_literal: true

module Ops
  # Emails KGen when Solid Queue has given up on a job. Runs every 15 minutes.
  # At most one email an hour. A failure of this job is ignored, so it cannot
  # alert about itself. A send error leaves the mark where it is; the next run
  # tries again. This job does not retry the send itself.
  class FailedJobsAlertJob < ApplicationJob
    queue_as :default

    COOLDOWN = 1.hour
    LIST_LIMIT = 50
    MARK = "failed_jobs"
    ALERT_CLASS = name
    DEFAULT_RECIPIENT = "realtoriq@kgen.tech"
    ZONE = "Asia/Kolkata"

    def perform
      to = recipient
      return if to.blank?

      mark = OpsAlertMark.for!(MARK)
      payload = payload_for(mark)
      return if payload.nil?
      return unless send_alert(to, payload)

      mark.update!(last_reported_at: payload[:newest], last_emailed_at: Time.current)
    end

    def recipient
      ENV["OPS_ALERT_EMAIL"].presence || (Rails.env.production? ? DEFAULT_RECIPIENT : nil)
    end

    private

    def payload_for(mark)
      mark.with_lock do
        next if cooling_down?(mark)

        failures = unreported(mark)
        next if failures.empty?

        {
          newest: failures.last.created_at,
          lines: failures.first(LIST_LIMIT).map { |failure| line_for(failure) },
          more: [ failures.size - LIST_LIMIT, 0 ].max,
          total: waiting_count
        }
      end
    end

    def send_alert(to, payload)
      OpsAlertMailer.failed_jobs(
        to:,
        lines: payload[:lines],
        more: payload[:more],
        total: payload[:total]
      ).deliver_now
      true
    rescue StandardError => error
      Rails.logger.error("[ops] failed job alert was not sent: #{error.class}")
      false
    end

    def cooling_down?(mark)
      mark.last_emailed_at.present? && mark.last_emailed_at > COOLDOWN.ago
    end

    def unreported(mark)
      scope = failures_scope.order("solid_queue_failed_executions.created_at ASC, solid_queue_failed_executions.id ASC")
      if mark.last_reported_at
        scope = scope.where("solid_queue_failed_executions.created_at > ?", mark.last_reported_at)
      end
      scope.to_a
    end

    def waiting_count
      failures_scope.count
    end

    def failures_scope
      SolidQueue::FailedExecution.joins(:job).includes(:job)
        .where.not(solid_queue_jobs: { class_name: ALERT_CLASS })
    end

    def line_for(failure)
      {
        at: failure.created_at.in_time_zone(ZONE).strftime("%-d %b, %-I:%M %p"),
        job_class: failure.job.class_name,
        error_class: failure.exception_class.to_s,
        message: FailureMessage.excerpt(failure.message)
      }
    end
  end
end
