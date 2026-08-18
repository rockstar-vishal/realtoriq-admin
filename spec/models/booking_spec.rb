# frozen_string_literal: true

require "rails_helper"

RSpec.describe Booking do
  let(:firm) { create(:firm) }

  before { Current.firm = firm }

  describe "net income" do
    it "matches the design's worked example exactly" do
      # ₹1.56 Cr at 4.5% is ₹7.02 L, plus a ₹50,000 kicker, minus a ₹66,000
      # passback — the design's screen shows ₹6.86 L.
      booking = create(:booking, firm:, agreement_value: 15_600_000,
        commission_percent: 4.5, kicker: 50_000, passback: 66_000)

      expect(booking.commission_amount).to eq(702_000)
      expect(booking.net_income).to eq(686_000)
    end

    it "rounds half-up, once, where the percentage meets the value" do
      # 4.35% of 1,23,45,678 is 5,37,036.993 — rounds to 5,37,037. This is the
      # case the whole-rupee decision accepts: the exact figure has paise, and
      # the stored one is a rupee away from it.
      booking = create(:booking, firm:, agreement_value: 12_345_678,
        commission_percent: 4.35, kicker: 0, passback: 0)

      expect(booking.net_income).to eq(537_037)
    end

    it "rounds a half-rupee up rather than to even" do
      # 0.5% of 1,00,001 is 500.005 → 500. 1% of 100_050 = 1000.5 → 1001.
      booking = create(:booking, firm:, agreement_value: 100_050,
        commission_percent: 1, kicker: 0, passback: 0)

      expect(booking.net_income).to eq(1_001)
    end

    it "recomputes when the agreement value is corrected" do
      booking = create(:booking, firm:, agreement_value: 10_000_000,
        commission_percent: 5, kicker: 0, passback: 0)
      expect(booking.net_income).to eq(500_000)

      booking.update!(agreement_value: 20_000_000)

      expect(booking.net_income).to eq(1_000_000)
    end

    it "can go negative if the passback exceeds the commission" do
      # Unusual but real, and better recorded than silently clamped to zero.
      booking = create(:booking, firm:, agreement_value: 1_000_000,
        commission_percent: 1, kicker: 0, passback: 50_000)

      expect(booking.net_income).to eq(-40_000)
    end
  end

  describe "codes" do
    it "numbers sequentially per firm" do
      expect(create(:booking, firm:).code).to eq("B-0001")
      expect(create(:booking, firm:).code).to eq("B-0002")
    end

    it "numbers each firm independently" do
      create(:booking, firm:)
      other = create(:firm)
      Current.firm = other

      expect(create(:booking, firm: other).code).to eq("B-0001")
    end
  end

  describe "totals" do
    let(:booking) do
      create(:booking, firm:, agreement_value: 10_000_000, commission_percent: 5,
        kicker: 0, passback: 0)
    end

    it "counts only raised invoices" do
      create(:invoice, firm:, booking:, amount: 200_000)
      create(:invoice, firm:, booking:, amount: 100_000, status: "cancelled")

      expect(booking.invoiced_total).to eq(200_000)
      expect(booking.invoiceable_balance).to eq(300_000)
    end

    it "reports what is still outstanding" do
      create(:invoice, firm:, booking:, amount: 400_000)
      create(:collection, firm:, booking:, amount: 150_000)

      expect(booking.collected_total).to eq(150_000)
      expect(booking.outstanding).to eq(250_000)
    end
  end

  describe "cancelling" do
    it "requires a reason" do
      booking = create(:booking, firm:)

      expect { booking.update!(status: "cancelled") }
        .to raise_error(ActiveRecord::RecordInvalid)
    end

    it "records the reason and leaves the lead alone" do
      lead = create(:lead, firm:)
      original_status = lead.lead_status
      booking = create(:booking, firm:, lead:)

      booking.cancel!(reason: "Client withdrew")

      expect(booking.reload).to be_cancelled
      # Cancelling touches the booking and nothing else — the lead is filed by
      # hand, per the product decision.
      expect(lead.reload.lead_status).to eq(original_status)
      expect(lead.booked_at).to be_nil
    end

    it "drops out of the live scope but keeps its invoices" do
      booking = create(:booking, firm:)
      create(:invoice, firm:, booking:)

      booking.cancel!(reason: "Client withdrew")

      expect(described_class.live).not_to include(booking)
      expect(booking.invoices.count).to eq(1)
    end
  end

  describe Invoice do
    it "refuses a duplicate number within a firm" do
      create(:invoice, firm:, number: "INV-1")

      expect(build(:invoice, firm:, number: "INV-1")).not_to be_valid
    end

    it "allows another firm the same number" do
      create(:invoice, firm:, number: "INV-1")
      other = create(:firm)
      Current.firm = other

      expect(build(:invoice, firm: other, booking: create(:booking, firm: other), number: "INV-1"))
        .to be_valid
    end

    it "reports what may still be collected against it" do
      invoice = create(:invoice, firm:, amount: 100_000)
      create(:collection, firm:, booking: invoice.booking, invoice:, amount: 40_000)

      expect(invoice.collectable_balance).to eq(60_000)
    end
  end

  describe Collection do
    it "refuses an invoice from a different booking" do
      other_invoice = create(:invoice, firm:)
      collection = build(:collection, firm:, booking: create(:booking, firm:), invoice: other_invoice)

      expect(collection).not_to be_valid
    end

    it "allows an unlinked payment" do
      expect(build(:collection, firm:, invoice: nil)).to be_valid
    end
  end
end
