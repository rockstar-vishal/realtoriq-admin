# frozen_string_literal: true

require "rails_helper"

# The three money blocks were read-then-write before this: check the balance,
# then insert, with nothing holding the row in between. Two requests arriving
# together each read a balance that neither had yet changed, both passed, and
# both saved — leaving a firm invoiced past what it earned, permanently, since
# invoices have no update or destroy route.
#
# These run with real threads and real connections, so transactional fixtures
# are off — a transaction wrapping the example would hide exactly the behaviour
# under test. Rows are cleaned up by hand.
RSpec.describe "Money hard blocks under concurrency" do
  self.use_transactional_tests = false

  let(:plan) { create(:plan) }
  let(:firm) { create(:firm, status: :active) }
  let(:user) { create(:user, :manager, firm:) }
  let(:lead) { create(:lead, firm:) }

  # net_income = round(1_000_000 x 10%) + 0 - 0 = 100_000
  let(:booking) do
    create(:booking, firm:, lead:, agreement_value: 1_000_000,
                     commission_percent: 10, kicker: 0, passback: 0)
  end

  # Transactional fixtures are off, so nothing rolls these rows back.
  #
  # Truncating everything rather than a hand-written list: deleting by hand
  # missed tables referencing firms, and truncating only firms+plans left the
  # global masters (lead_statuses, typologies — no firm_id, so CASCADE does not
  # reach them) to collide with the factory sequences on the next run. The
  # factories build everything they need, so nothing here depends on seeds.
  def truncate_everything
    conn = ActiveRecord::Base.connection
    tables = conn.tables - %w[schema_migrations ar_internal_metadata]
    conn.execute("TRUNCATE TABLE #{tables.map { |t| conn.quote_table_name(t) }.join(', ')} RESTART IDENTITY CASCADE")
  end

  before do
    truncate_everything
    Current.firm = firm
  end

  after do
    Current.firm = nil
    truncate_everything
  end

  # Threads block on a queue so they reach the service together rather than in
  # whatever order they happened to start.
  def race(count)
    latch = Queue.new
    threads = Array.new(count) do |i|
      Thread.new do
        latch.pop
        ActiveRecord::Base.connection_pool.with_connection do
          Current.firm = firm
          yield i
        end
      end
    end
    count.times { latch << :go }
    threads.map(&:value)
  end

  it "lets exactly one of four concurrent invoices through" do
    expect(booking.net_income).to eq(100_000)

    results = race(4) do |i|
      Bookings::RaiseInvoice.new(
        booking: Booking.find(booking.id),
        attributes: { number: "RACE-#{i}", issued_on: Date.current, amount: 100_000 },
        actor: user
      ).call
    end

    expect(results.count(&:ok?)).to eq(1)
    expect(results.count { |r| r.error_code == "over_invoiced" }).to eq(3)

    booking.reload
    expect(booking.invoiced_total).to eq(100_000)
    # The figure that went negative before the lock existed.
    expect(booking.invoiceable_balance).to eq(0)
  end

  it "lets exactly one of four concurrent collections through" do
    create(:invoice, firm:, booking:, amount: 100_000, number: "INV-RACE")

    results = race(4) do
      Bookings::RecordCollection.new(
        booking: Booking.find(booking.id),
        attributes: { received_on: Date.current, amount: 100_000, mode: "neft_rtgs" },
        actor: user
      ).call
    end

    expect(results.count(&:ok?)).to eq(1)
    expect(results.count { |r| r.error_code == "over_collected" }).to eq(3)

    booking.reload
    expect(booking.collected_total).to eq(100_000)
    expect(booking.outstanding).to eq(0)
  end

  it "lets exactly one of four concurrent collections through against one invoice" do
    # Sized so the booking-level check cannot be what refuses these: four
    # collections of 25k total 100k, exactly what is invoiced across both
    # invoices, so `over_collected` never fires and the per-invoice block has to
    # do the work alone. Invoice A can only take one of them.
    invoice = create(:invoice, firm:, booking:, amount: 25_000, number: "INV-A")
    create(:invoice, firm:, booking:, amount: 75_000, number: "INV-B")

    results = race(4) do
      Bookings::RecordCollection.new(
        booking: Booking.find(booking.id),
        invoice: Invoice.find(invoice.id),
        attributes: { received_on: Date.current, amount: 25_000, mode: "neft_rtgs" },
        actor: user
      ).call
    end

    expect(results.count(&:ok?)).to eq(1)
    expect(results.count { |r| r.error_code == "over_collected_for_invoice" }).to eq(3)
    expect(invoice.reload.collected_total).to eq(25_000)
  end
end
