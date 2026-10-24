# frozen_string_literal: true

require "rails_helper"

RSpec.describe "booking money writes" do
  let(:firm) { create(:firm) }
  let(:booking) do
    create(:booking, firm:, agreement_value: 10_000_000, commission_percent: 1, kicker: 0, passback: 0)
  end

  before { Current.firm = firm }

  it "refuses an invoice against the live sum when the stored total is still zero" do
    create(:invoice, firm:, booking:, amount: 100_000)
    expect(booking.reload.invoiced_amount).to eq(0)

    result = Bookings::RaiseInvoice.new(
      booking:, attributes: { number: "INV-STALE", issued_on: Date.current, amount: 1 }
    ).call

    expect(result.ok?).to be(false)
    expect(result.error_code).to eq("over_invoiced")
    expect(result.details[:already_invoiced]).to eq(100_000)
    expect(booking.reload.invoiced_amount).to eq(0)
  end

  it "stores both totals when a collection lands against a factory invoice" do
    create(:invoice, firm:, booking:, amount: 100_000, number: "INV-LIVE")
    expect(booking.reload.invoiced_amount).to eq(0)

    result = Bookings::RecordCollection.new(
      booking:, attributes: { received_on: Date.current, amount: 100_000, mode: "upi" }
    ).call

    expect(result.ok?).to be(true)
    booking.reload
    expect(booking.invoiced_amount).to eq(100_000)
    expect(booking.collected_amount).to eq(100_000)
  end
end
