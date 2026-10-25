# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Configuration categories" do
  let(:firm) { create(:firm) }

  before { Current.firm = firm }

  describe "backfill" do
    it "merges 2BHK Ultima, keeps 5 BHK beside 5+ BHK, and a second run changes nothing" do
      city = create(:city)
      locality = create(:locality, city:)
      variant = create(:typology, name: "2BHK Ultima", code: "2bhk_ultima")
      property = create(:property, firm:, city:, locality:, typology: variant)
      lead = create(:lead, firm:)
      lead.typologies << variant
      project = create(:project, firm:)
      row = create(:project_typology, project:, typology: variant, label: nil)

      Inventory::CategoriesBackfill.call(output: StringIO.new)
      canonical = Typology.find_by!(code: "2_bhk")

      expect(Typology.find_by!(code: "5_bhk").name).to eq("5 BHK")
      expect(Typology.find_by!(code: "5_plus_bhk").name).to eq("5+ BHK")
      expect(property.reload.typology).to eq(canonical)
      expect(lead.reload.typologies).to contain_exactly(canonical)
      expect(row.reload.typology).to eq(canonical)
      expect(row.label).to eq("2BHK Ultima")
      expect(ConfigurationAlias.find_by!(key: "2bhkultima").typology).to eq(canonical)

      aliases = ConfigurationAlias.count
      Inventory::CategoriesBackfill.call(output: StringIO.new)

      expect(ConfigurationAlias.count).to eq(aliases)
      expect(property.reload.typology).to eq(canonical)
      expect(Typology.where(code: "5_plus_bhk").count).to eq(1)
    end

    it "adopts the frozen production table" do
      two = create(:typology, name: "2 BHK", code: "2_bhk")
      old_two = create(:typology, name: "2BHK", code: "2bhk")
      four = create(:typology, name: "4BHK", code: "4bhk")
      villa = create(:typology, name: "3BHK Villa", code: "3bhk_villa")
      commercial = create(:typology, name: "Commercial", code: "commercial")
      leads = Array.new(4) { create(:lead, firm:) }
      leads.each { |lead| lead.typologies << old_two }
      leads.first.typologies << two
      commercial_lead = create(:lead, firm:)
      commercial_lead.typologies << commercial

      four_row = catalog_row(four)
      villa_row = catalog_row(villa)
      commercial_row = catalog_row(commercial)
      output = StringIO.new

      Inventory::CategoriesBackfill.call(output:)

      office = Typology.find_by!(code: "office")
      expect(office).to be_active
      expect(Typology.find_by!(code: "2bhk").merged_into).to eq(two)
      expect(leads.first.reload.typologies).to contain_exactly(two)
      expect(LeadTypology.where(typology: old_two)).to be_empty
      expect(four_row.reload.label).to be_nil
      expect(four_row.typology.code).to eq("4_bhk")
      expect(villa_row.reload.label).to eq("3BHK Villa")
      expect(villa_row.typology.code).to eq("3_bhk")
      expect(commercial_row.reload.typology).to eq(office)
      expect(commercial_row.label).to be_nil
      expect(commercial_lead.reload.category).to eq("commercial")
      expect(commercial_lead.typologies).to contain_exactly(office)
      expect(ConfigurationAlias.where(key: %w[2bhk 4bhk 3bhkvilla]).pluck(:key)).to contain_exactly("2bhk", "4bhk", "3bhkvilla")
      expect(ConfigurationAlias.find_by(key: "commercial")).to be_nil
      expect(Typology.find_by!(code: "showroom")).not_to be_active
      expect(Typology.find_by!(code: "shop")).not_to be_active
      expect(Typology.find_by!(code: "residential_plot")).not_to be_active
      %w[4_5_bhk 5_bhk 5_plus_bhk row_house].each do |code|
        expect(Typology.find_by!(code:)).to be_active
      end
      expect(output.string).to include("Land listings for rent: none")
      expect(output.string).to include("2BHK -> 2 BHK (residential -> residential)")
      expect(output.string).to include("4BHK -> 4 BHK (residential -> residential)")
      expect(output.string).to include("3BHK Villa -> 3 BHK (residential -> residential)")
      expect(output.string).to include("Commercial -> Office (residential -> commercial, no alias)")
      expect(output.string).to include("Re-categorised #{commercial_lead.code}")
    end

    it "writes nothing when DRY_RUN=1" do
      create(:typology, name: "Duplex", code: "duplex")
      output = StringIO.new

      Inventory::CategoriesBackfill.call(dry_run: true, output:)

      expect(output.string).to include("[dry run]")
      expect(output.string).to include("Flagged Duplex")
      expect(Typology.find_by(code: "office")).to be_nil
      expect(Typology.find_by!(code: "duplex").needs_review).to be(false)
    end

    it "names a trimmed lead and a lead that needs manual review" do
      two = create(:typology, name: "2 BHK", code: "2_bhk")
      commercial = create(:typology, name: "Commercial", code: "commercial")
      cold = create(:typology, name: "Cold storage", code: "cold_storage", category: "commercial")
      parcel = create(:typology, name: "Farm parcel", code: "farm_parcel", category: "land")
      mixed = create(:lead, firm:)
      mixed.typologies << commercial << two
      unresolved = create(:lead, firm:)
      # These joins predate the category check. A residential lead can already
      # be holding a commercial configuration and a plot.
      [ cold, parcel ].each do |typology|
        unresolved.lead_typologies.build(typology:).save!(validate: false)
      end
      output = StringIO.new

      Inventory::CategoriesBackfill.call(dry_run: true, output:)

      expect(output.string).to include("Trimmed #{mixed.code}")
      expect(output.string).to include("#{unresolved.code} needs manual review")
      expect(output.string).to include("Flagged Cold storage")
      expect(output.string).to include("Flagged Farm parcel")
      expect(mixed.reload.category).to eq("residential")
      expect(mixed.typologies).to include(commercial)
    end
  end

  describe "an in-use unconfirmed configuration" do
    it "keeps Shop visible, merges Retail Shop, and then refuses a confirmed change" do
      shop = create(:typology, name: "Shop", code: "shop", active: true)
      retail = create(:typology, name: "Retail Shop", code: "retail_shop", active: true)
      create(:property, firm:, typology: shop)
      catalog_row(retail)

      Inventory::CategoriesBackfill.call(output: StringIO.new)
      shop.reload

      expect(shop.category).to eq("commercial")
      expect(shop.category_confirmed_at).to be_present
      expect(shop).to be_active
      expect(retail.reload.merged_into).to eq(shop)
      expect(ConfigurationAlias.find_by!(key: "retailshop").source).to eq("merge")
      expect(Typology.find_by!(code: "showroom")).not_to be_active

      Current.admin_user = create(:admin_user)
      expect { shop.update!(category: "residential") }.to raise_error(ActiveRecord::RecordInvalid)
      shop.reload
      two = Typology.find_by!(code: "2_bhk")
      expect { shop.merge_into!(two) }.to raise_error(ActiveRecord::RecordInvalid)
    end

    it "moves a lead onto the target category, and keeps a residential mix residential" do
      office = create(:typology, name: "Office", code: "office", category: "commercial")
      commercial = create(:typology, name: "Commercial", code: "commercial")
      two = create(:typology, name: "2 BHK", code: "2_bhk")
      only = create(:lead, firm:)
      only.typologies << commercial
      mixed = create(:lead, firm:)
      mixed.typologies << commercial << two

      commercial.merge_into!(office)

      expect(only.reload.category).to eq("commercial")
      expect(only.typologies).to contain_exactly(office)
      expect(mixed.reload.category).to eq("residential")
      expect(mixed.typologies).to contain_exactly(two)
      expect(mixed.lead_activities.find_by!(kind: "note").body).to eq(
        "Removed Commercial configurations when this enquiry was filed as Residential."
      )
    end

    it "moves a booking onto the target, and Form 6 reads that category" do
      flat = create(:typology, name: "2 BHK", code: "flat_merge", category: "residential")
      shop = create(:typology, name: "Shop", code: "shop_merge", category: "commercial")
      project = create(:project, firm:)
      booking = create(:booking, firm:, project:, unit_no: "A-1", typology: flat, booked_on: Date.new(2026, 5, 1))

      expect(flat.referenced?).to be(true)

      flat.merge_into!(shop)
      booking.reload

      expect(booking.typology_id).to eq(shop.id)
      row = Form6::Report.new(firm:, period: Form6::Period.parse("2026-04")).table_b_rows.find { |item| item.id == booking.id }
      expect(Form6::Classification.category_label(row.typology)).to eq("Commercial")
    end

    it "leaves a review alias in place when the same name is merged" do
      shop = create(:typology, name: "Shop", code: "shop", category: "commercial")
      showroom = create(:typology, name: "Showroom", code: "showroom", category: "commercial")
      ConfigurationAlias.create!(key: "retailshop", typology: showroom, source: "review")
      retail = create(:typology, name: "Retail Shop", code: "retail_shop")

      retail.merge_into!(shop)

      expect(ConfigurationAlias.find_by!(key: "retailshop").typology).to eq(showroom)
      expect(ConfigurationAlias.find_by!(key: "retailshop").source).to eq("review")
    end
  end

  def catalog_row(typology)
    project = Current.set(firm: nil, firm_scope_bypassed: true) do
      create(:project, :catalog, firm: nil, external_ref: "PR#{SecureRandom.hex(3).upcase}")
    end
    create(:project_typology, project:, typology:)
  end
end
