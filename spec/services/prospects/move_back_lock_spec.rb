# frozen_string_literal: true

require "rails_helper"

# Move-back deletes an unworked lead. A booking or visit inserted without
# locking that lead can land after the check and be destroyed with it.
# These run on real connections: a transaction around the example would hide
# the other thread's lock. Ids are captured before the threads start, because
# a `let` touched inside a thread can build a second firm.
RSpec.describe "Move-back waits for activity on the lead" do
  self.use_transactional_tests = false

  let(:plan) { create(:plan) }
  let(:firm) { create(:firm, status: :active) }
  let(:user) { create(:user, :manager, firm:) }
  let(:lead) { create(:lead, firm:) }

  def truncate_everything
    conn = ActiveRecord::Base.connection
    tables = conn.tables - %w[schema_migrations ar_internal_metadata]
    conn.execute("TRUNCATE TABLE #{tables.map { |table| conn.quote_table_name(table) }.join(", ")} RESTART IDENTITY CASCADE")
  end

  before do
    truncate_everything
    Current.firm = firm
  end

  after do
    Current.firm = nil
    truncate_everything
  end

  def while_lead_locked(locked_lead, tenant)
    started = Queue.new
    release = Queue.new
    holder = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        Current.firm = tenant
        Lead.transaction do
          Lead.lock.find(locked_lead.id)
          started << true
          release.pop
        end
      end
    end
    started.pop
    begin
      yield
    ensure
      release << true
      holder.join
    end
  end

  # The holder already has the lead row. A writer that locks it hits
  # lock_timeout. A writer that skips the lock finishes and saves.
  def attempt_while_locked(tenant)
    error = nil
    result = nil
    worker = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        Current.firm = tenant
        ActiveRecord::Base.connection.execute("SET lock_timeout = '400ms'")
        begin
          result = yield
        rescue ActiveRecord::LockWaitTimeout => e
          error = e
        ensure
          ActiveRecord::Base.connection.execute("RESET lock_timeout")
        end
      end
    end
    worker.join(5)
    [ error, result ]
  end

  it "will not save a booking while move-back could still delete the lead" do
    tenant = firm
    locked_lead = lead
    actor = user

    while_lead_locked(locked_lead, tenant) do
      error, result = attempt_while_locked(tenant) do
        Bookings::Create.new(
          firm: tenant, actor:, lead: Lead.find(locked_lead.id),
          attributes: {
            booked_on: Date.current, agreement_value: 1_000_000,
            commission_percent: 2, kicker: 0, passback: 0
          }
        ).call
      end

      expect(error).to be_a(ActiveRecord::LockWaitTimeout)
      expect(result).to be_nil
    end

    expect(Booking.unscoped.where(lead_id: locked_lead.id)).to be_empty
  end

  it "will not save a visit while move-back could still delete the lead" do
    tenant = firm
    locked_lead = lead
    actor = user

    while_lead_locked(locked_lead, tenant) do
      error, result = attempt_while_locked(tenant) do
        Leads::RecordVisit.new(
          lead: Lead.find(locked_lead.id), actor:,
          attributes: { visited_on: Date.current.iso8601, notes: "Saw the flat", project_ids: [], property_ids: [] }
        ).call
      end

      expect(error).to be_a(ActiveRecord::LockWaitTimeout)
      expect(result).to be_nil
    end

    expect(LeadVisit.unscoped.where(lead_id: locked_lead.id)).to be_empty
  end
end
