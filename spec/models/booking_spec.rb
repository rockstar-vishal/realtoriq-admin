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

    it "counts only raised invoices, from the stored total" do
      create(:invoice, firm:, booking:, amount: 200_000)
      create(:invoice, firm:, booking:, amount: 100_000, status: "cancelled")

      # A factory invoice does not rewrite the column. The readers are the
      # columns; RaiseInvoice is what fills them.
      expect(booking.invoiced_total).to eq(0)

      booking.refresh_money!

      expect(booking.invoiced_amount).to eq(200_000)
      expect(booking.invoiced_total).to eq(200_000)
      expect(booking.invoiceable_balance).to eq(300_000)
    end

    it "reports what is still outstanding from the stored totals" do
      create(:invoice, firm:, booking:, amount: 400_000)
      create(:collection, firm:, booking:, amount: 150_000)

      expect(booking.collected_total).to eq(0)
      booking.refresh_money!

      expect(booking.collected_amount).to eq(150_000)
      expect(booking.collected_total).to eq(150_000)
      expect(booking.outstanding).to eq(250_000)
    end

    it "reads the stored columns even when the live sums disagree" do
      create(:invoice, firm:, booking:, amount: 200_000)
      booking.update_columns(invoiced_amount: 12, collected_amount: 7)

      expect(booking.invoiced_total).to eq(12)
      expect(booking.collected_total).to eq(7)
      expect(booking.outstanding).to eq(5)
    end

    it "sums each booking's still-to-invoice balance, not the gap between the sums" do
      under = create(:booking, firm:, agreement_value: 10_000_000, commission_percent: 1,
        kicker: 0, passback: 0)
      over = create(:booking, firm:, agreement_value: 10_000_000, commission_percent: 1,
        kicker: 0, passback: 0)
      under.update_columns(net_income: 100, invoiced_amount: 80, collected_amount: 10)
      over.update_columns(net_income: 100, invoiced_amount: 150, collected_amount: 40)

      totals = described_class.money_totals(described_class.where(id: [ under.id, over.id ]))

      expect(totals).to include(invoiced: 230, collected: 50, outstanding: 180, to_invoice: 20)
    end
  end

  describe "stage" do
    def staged(status:, net:, invoiced:, collected:)
      booking = create(:booking, firm:, agreement_value: 1_000_000, commission_percent: 1,
        kicker: 0, passback: 0)
      booking.update_columns(
        status:, net_income: net, invoiced_amount: invoiced, collected_amount: collected,
        cancelled_at: status == "cancelled" ? Time.current : nil,
        cancellation_reason: status == "cancelled" ? "Client withdrew" : nil
      )
      booking.reload
    end

    # Paid wins over awaiting. Cancelled wins over paid. An invoice that has
    # been collected in full is to_invoice, not awaiting.
    [
      { status: "cancelled", net: 100, invoiced: 200, collected: 200, stage: "cancelled" },
      { status: "live", net: 0, invoiced: 0, collected: 0, stage: "paid" },
      { status: "live", net: -40, invoiced: 0, collected: 0, stage: "paid" },
      { status: "live", net: 100, invoiced: 120, collected: 100, stage: "paid" },
      { status: "live", net: 100, invoiced: 100, collected: 100, stage: "paid" },
      { status: "live", net: 500, invoiced: 100, collected: 100, stage: "to_invoice" },
      { status: "live", net: 500, invoiced: 100, collected: 0, stage: "awaiting_payment" },
      { status: "live", net: 500, invoiced: 0, collected: 0, stage: "to_invoice" }
    ].each do |row|
      it "is #{row[:stage]} when status=#{row[:status]} net=#{row[:net]} invoiced=#{row[:invoiced]} collected=#{row[:collected]}" do
        booking = staged(**row.except(:stage))

        expect(booking.stage).to eq(row[:stage])
        Booking::STAGES.each do |stage|
          expect(Booking.in_stage(stage).where(id: booking.id).exists?).to eq(stage == row[:stage])
        end
      end
    end
  end

  describe "configuration" do
    it "must be a configuration of the booking's project" do
      project = create(:project, firm:)
      other = create(:project_typology, project: create(:project, firm:))

      booking = build(:booking, firm:, project:, unit_no: "A-1", project_typology: other)

      expect(booking).not_to be_valid
      expect(booking.errors[:project_typology_id]).to include("isn't a configuration of this project")
    end

    it "drops a configuration when the booking has no project" do
      row = create(:project_typology)
      booking = build(:booking, firm:, project: nil, unit_no: nil, project_typology: row, typology: row.typology,
        configuration_label: "Ultima")

      expect(booking).to be_valid
      expect(booking.project_typology_id).to be_nil
      expect(booking.typology_id).to be_nil
      expect(booking.configuration_label).to be_nil
    end

    it "keeps the snapshot when the configuration row is deleted" do
      project = create(:project, firm:)
      typology = create(:typology, name: "2 BHK")
      row = create(:project_typology, project:, typology:, label: "Ultima")
      booking = create(:booking, firm:, project:, unit_no: "A-1", project_typology: row)

      row.destroy!

      booking.reload
      expect(booking.project_typology_id).to be_nil
      expect(booking.typology_id).to eq(typology.id)
      expect(booking.configuration_label).to eq("Ultima")
    end
  end

  describe "units" do
    it "requires a unit number when a project is set" do
      expect(build(:booking, firm:, project: create(:project, firm:), unit_no: nil)).not_to be_valid
    end

    it "can cancel a legacy row that has a project and no unit" do
      booking = create(:booking, firm:, project: create(:project, firm:), unit_no: "TEMP")
      booking.update_columns(unit_no: nil)

      expect { booking.cancel!(reason: "Client withdrew") }.not_to raise_error
      expect(booking.reload).to be_cancelled
    end

    it "allows a booking with no project and no unit" do
      expect(build(:booking, firm:, project: nil, unit_no: nil)).to be_valid
    end

    it "refuses a second live booking of the same unit on a project" do
      project = create(:project, firm:)
      create(:booking, firm:, project:, unit_no: "B-1104")

      expect(build(:booking, firm:, project:, unit_no: "B-1104")).not_to be_valid
    end

    it "frees the unit after cancel" do
      project = create(:project, firm:)
      booking = create(:booking, firm:, project:, unit_no: "B-1104")
      booking.cancel!(reason: "Client withdrew")

      expect(build(:booking, firm:, project:, unit_no: "B-1104")).to be_valid
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

  describe "a listing" do
    let(:typology) { create(:typology, name: "2 BHK") }
    let(:property) { create(:property, firm:, typology:) }

    it "snapshots the listing's typology and keeps it when the listing changes" do
      booking = create(:booking, firm:, property:, project: nil, unit_no: nil)

      expect(booking.typology_id).to eq(typology.id)
      expect(booking.configuration_label).to be_nil
      expect(booking).to be_valid

      property.update!(typology: create(:typology, name: "3 BHK"))
      booking.update!(other_details: "kept")

      expect(booking.reload.typology_id).to eq(typology.id)
    end

    it "refuses a project and a listing together" do
      booking = build(:booking, firm:, property:, project: create(:project, firm:), unit_no: "A-1")

      expect(booking).not_to be_valid
      expect(booking.link_problem[:code]).to eq("project_and_listing")
    end

    it "refuses a listing the firm cannot see" do
      hidden = create(:property, firm: create(:firm), typology:, listed_on_marketplace: false)
      booking = build(:booking, firm:, property: hidden)

      expect(booking).not_to be_valid
      expect(booking.errors.of_kind?(:property_id, :listing_not_found)).to be(true)
    end

    it "allows the firm's own listing after it is sold out" do
      property.update!(status: "sold_out")

      expect(build(:booking, firm:, property:)).to be_valid
    end

    it "refuses a second live booking of the same listing in the firm" do
      first = create(:booking, firm:, property:)
      again = build(:booking, firm:, property:)

      expect(again).not_to be_valid
      expect(again.link_problem).to include(
        code: "listing_already_booked",
        details: { booking_id: first.id, code: first.code }
      )
    end

    it "lets a second firm book the same marketplace listing" do
      other = create(:firm, status: :active)
      Current.firm = other

      expect(build(:booking, firm: other, property:)).to be_valid
    end

    it "frees the listing when the live booking is cancelled" do
      create(:booking, firm:, property:).cancel!(reason: "Client withdrew")

      expect(build(:booking, firm:, property:)).to be_valid
    end

    it "puts the firm's own booked listing back only when cancel asks" do
      property.update!(status: "booked")
      booking = create(:booking, firm:, property:)
      booking.cancel!(reason: "Client withdrew", release_property: true)

      expect(property.reload).to be_available
      event = AuditEvent.find_by!(action: "property.status_changed", subject: property)
      expect(event.metadata).to include("from" => "booked", "to" => "available", "booking_id" => booking.id)
    end

    it "leaves the listing booked when cancel does not release it" do
      property.update!(status: "booked")
      create(:booking, firm:, property:).cancel!(reason: "Client withdrew")

      expect(property.reload).to be_booked
      expect(AuditEvent.where(action: "property.status_changed", subject: property)).to be_none
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
