# frozen_string_literal: true

require "rails_helper"

RSpec.describe Ops::FailureMessage do
  it "scrubs a url, a token, an email address and a long number" do
    raw = "see https://files.example.com/a token=abc user@example.com ref 123456789012"

    expect(described_class.scrub(raw)).to eq("see [url] token=[hidden] [email] ref [number]")
    expect(described_class.excerpt("y" * 200).length).to eq(140)
  end
end

RSpec.describe Ops::FailedJobsAlertJob do
  before(:all) do
    connection = SolidQueue::Record.connection
    next if connection.table_exists?(:solid_queue_jobs)

    connection.create_table :solid_queue_jobs do |t|
      t.string :queue_name, null: false
      t.string :class_name, null: false
      t.text :arguments
      t.integer :priority, default: 0, null: false
      t.string :active_job_id
      t.datetime :scheduled_at
      t.datetime :finished_at
      t.string :concurrency_key
      t.timestamps null: false
    end

    connection.create_table :solid_queue_failed_executions do |t|
      t.bigint :job_id, null: false
      t.text :error
      t.datetime :created_at, null: false
      t.index :job_id, unique: true
    end
  end

  around do |example|
    previous = ENV.fetch("OPS_ALERT_EMAIL", nil)
    ENV.delete("OPS_ALERT_EMAIL")
    ActionMailer::Base.deliveries.clear
    example.run
  ensure
    travel_back
    if previous.nil?
      ENV.delete("OPS_ALERT_EMAIL")
    else
      ENV["OPS_ALERT_EMAIL"] = previous
    end
  end

  # insert_all skips Job's after_create, which would require the rest of the queue tables.
  def fail_job(class_name, message:, at:, error_class: "RuntimeError", arguments: {})
    job_id = SolidQueue::Job.insert_all!([ {
      queue_name: "default",
      class_name:,
      arguments: arguments.to_json,
      priority: 0,
      created_at: at,
      updated_at: at
    } ], returning: %w[id]).first.fetch("id")

    failure_id = SolidQueue::FailedExecution.insert_all!([ {
      job_id:,
      error: { exception_class: error_class, message: },
      created_at: at
    } ], returning: %w[id]).first.fetch("id")

    SolidQueue::FailedExecution.find(failure_id)
  end

  def mail_body
    mail = ActionMailer::Base.deliveries.last
    source = mail.html_part ? mail.html_part.body.decoded : mail.body.decoded
    CGI.unescapeHTML(source)
  end

  context "in production" do
    before { allow(Rails.env).to receive(:production?).and_return(true) }

    it "sends nothing when nothing has failed" do
      described_class.perform_now

      expect(ActionMailer::Base.deliveries).to be_empty
    end

    it "emails both new failures to the default address and moves the mark" do
      fail_job("Realtoriq::SyncProjectAssetsJob", message: "brochure missing", at: Time.zone.local(2026, 10, 28, 11, 12))
      newer = fail_job(
        "ActiveStorage::PurgeJob",
        message: "object gone",
        at: Time.zone.local(2026, 10, 28, 11, 40),
        error_class: "Aws::S3::Errors::ServiceError",
        arguments: { "token" => "argument-value" }
      )

      described_class.perform_now

      mail = ActionMailer::Base.deliveries.last
      expect(ActionMailer::Base.deliveries.size).to eq(1)
      expect(mail.to).to eq([ "realtoriq@kgen.tech" ])
      expect(mail.from).to eq([ "realtoriq-noreply@mail.kgen.tech" ])
      expect(mail.subject).to eq("RealtorIQ: 2 Background Jobs Failed")
      expect(mail_body).to include("28 Oct, 11:12 AM — Realtoriq::SyncProjectAssetsJob — RuntimeError — brochure missing")
      expect(mail_body).to include("28 Oct, 11:40 AM — ActiveStorage::PurgeJob — Aws::S3::Errors::ServiceError — object gone")
      expect(mail_body).to include("2 failed jobs are waiting in total")
      expect(mail_body).to include(Ops::FailedJobCommands::LOOK)
      expect(mail_body).to include(Ops::FailedJobCommands::RETRY_OR_DISCARD)
      expect(mail_body).not_to include("argument-value")
      expect(mail_body.index("11:12 AM")).to be < mail_body.index("11:40 AM")

      mark = OpsAlertMark.find_by!(name: "failed_jobs")
      expect(mark.last_reported_at).to be_within(1.second).of(newer.created_at)
      expect(mark.last_emailed_at).to be_present

      doc = Rails.root.join("docs/operations.md").read
      expect(doc).to include(Ops::FailedJobCommands::LOOK)
      expect(doc).to include(Ops::FailedJobCommands::RETRY_OR_DISCARD)
    end

    it "holds a failure that arrives inside the hour, then emails only that one" do
      travel_to Time.zone.local(2026, 10, 28, 11, 0)
      fail_job("OldJob", message: "first", at: Time.zone.local(2026, 10, 28, 10, 0))
      second = fail_job("SecondJob", message: "second", at: Time.zone.local(2026, 10, 28, 10, 30))
      described_class.perform_now
      expect(ActionMailer::Base.deliveries.size).to eq(1)

      travel_to Time.zone.local(2026, 10, 28, 11, 20)
      fail_job("ThirdJob", message: "late", at: Time.current)
      described_class.perform_now

      expect(ActionMailer::Base.deliveries.size).to eq(1)
      mark = OpsAlertMark.find_by!(name: "failed_jobs")
      expect(mark.last_reported_at).to be_within(1.second).of(second.created_at)
      expect(mark.last_emailed_at).to be_within(1.second).of(Time.zone.local(2026, 10, 28, 11, 0))

      travel_to Time.zone.local(2026, 10, 28, 12, 1)
      described_class.perform_now

      expect(ActionMailer::Base.deliveries.size).to eq(2)
      expect(ActionMailer::Base.deliveries.last.subject).to eq("RealtorIQ: 1 Background Job Failed")
      expect(mail_body).to include("28 Oct, 11:20 AM — ThirdJob — RuntimeError — late")
      expect(mail_body).not_to include("OldJob")
      expect(mail_body).not_to include("SecondJob")
      expect(mail_body).to include("3 failed jobs are waiting in total")
    end

    it "scrubs the message that is emailed" do
      dirty = "see https://files.example.com/a token=abc user@example.com ref 123456789012"
      fail_job("ReportJob", message: dirty, at: Time.zone.local(2026, 10, 28, 11, 12))

      described_class.perform_now

      expect(mail_body).to include("see [url] token=[hidden] [email] ref [number]")
      expect(mail_body).not_to include("files.example.com")
      expect(mail_body).not_to include("token=abc")
      expect(mail_body).not_to include("user@example.com")
      expect(mail_body).not_to include("123456789012")
    end

    it "never lists a failed run of itself" do
      fail_job("Ops::FailedJobsAlertJob", message: "smtp down", at: Time.zone.local(2026, 10, 28, 11, 0))
      fail_job("KeepJob", message: "real", at: Time.zone.local(2026, 10, 28, 11, 1))

      described_class.perform_now

      expect(mail_body).to include("KeepJob")
      expect(mail_body).not_to include("Ops::FailedJobsAlertJob")
      expect(mail_body).to include("1 failed job is waiting in total")
    end

    it "leaves the mark where it is when the email cannot be sent" do
      fail_job("KeepJob", message: "real", at: Time.zone.local(2026, 10, 28, 11, 1))
      delivery = instance_double(ActionMailer::MessageDelivery)
      allow(OpsAlertMailer).to receive(:failed_jobs).and_return(delivery)
      allow(delivery).to receive(:deliver_now).and_raise(IOError, "delivery failed")

      expect { described_class.perform_now }.not_to raise_error

      mark = OpsAlertMark.find_by!(name: "failed_jobs")
      expect(mark.last_reported_at).to be_nil
      expect(mark.last_emailed_at).to be_nil
      expect(ActionMailer::Base.deliveries).to be_empty

      allow(OpsAlertMailer).to receive(:failed_jobs).and_call_original
      described_class.perform_now

      expect(ActionMailer::Base.deliveries.size).to eq(1)
      expect(mark.reload.last_reported_at).to be_present
    end

    it "moves the mark past failures that the email only counts" do
      base = Time.zone.local(2026, 10, 28, 9, 0)
      51.times do |index|
        fail_job("Bulk#{index}", message: "m#{index}", at: base + index.minutes)
      end

      described_class.perform_now

      expect(ActionMailer::Base.deliveries.last.subject).to eq("RealtorIQ: 51 Background Jobs Failed")
      expect(mail_body).to include("Bulk0")
      expect(mail_body).to include("Bulk49")
      expect(mail_body).not_to include("Bulk50")
      expect(mail_body).to include("and 1 more")
      expect(OpsAlertMark.find_by!(name: "failed_jobs").last_reported_at).to be_within(1.second).of(base + 50.minutes)
    end
  end

  it "sends nothing from staging when OPS_ALERT_EMAIL is unset" do
    fail_job("KeepJob", message: "real", at: Time.zone.local(2026, 10, 28, 11, 1))

    described_class.perform_now

    expect(ActionMailer::Base.deliveries).to be_empty
    expect(OpsAlertMark.count).to eq(0)
  end
end
