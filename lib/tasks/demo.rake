# frozen_string_literal: true

namespace :demo do
  desc "Create a demo firm you can sign into (development/staging only)"
  task seed: :environment do
    # Kept out of db:seed on purpose. Reference data belongs in every database;
    # a fake brokerage does not, and an environment guard inside a file everyone
    # runs is a thinner defence than simply not running it.
    abort("demo:seed must never run in production") if Rails.env.production?

    abort("Run bin/rails db:seed first — demo data builds on the masters.") if Plan.active.none?

    ActiveRecord::Base.transaction do
      Current.firm_scope_bypassed = true

      city = City.find_by!(name: "Navi Mumbai")
      locality = Locality.find_by!(city:, name: "Kharghar")
      plan = Plan.active.find_by(name: "Growth") || Plan.active.ordered.first

      firm = Firm.find_or_initialize_by(slug: "sethi-realty")
      firm.assign_attributes(
        name: "Sethi Realty",
        legal_name: "Sethi Realty Pvt Ltd",
        status: :active,
        activated_at: firm.activated_at || Time.current,
        primary_contact_name: "Tanmay Sethi",
        rera_number: "A52100012345",
        pan: "ABCDE1234F",
        address_line1: "Unit 402, Vardhman Chambers",
        city:, locality:, pincode: "410210",
        internal_notes: "Demo firm created by `bin/rails demo:seed`. Safe to delete."
      )
      firm.save!

      # Email and mobile verified, WhatsApp deliberately left unverified: it
      # gives the panel a finished-looking firm that still has one channel to
      # walk through, and it means the verification flow is demonstrable on a
      # freshly seeded database. Reset every run so the state is deterministic.
      {
        "email" => [ "ops@sethirealty.in", true ],
        "mobile" => [ "+919820100001", true ],
        "whatsapp" => [ "+919930071234", false ]
      }.each do |kind, (value, verified)|
        channel = firm.contact_channels.find_or_initialize_by(kind:)
        channel.value = value
        channel.save!

        verified ? channel.mark_verified! : channel.reset_verification!
      end

      # One of each role, so permission behaviour is visible without editing
      # anything: only the super admin can verify the firm's channels.
      [
        [ "Tanmay Sethi", "tanmay@sethirealty.in", "+919820144210", :super_admin ],
        [ "Priya Nair",   "priya@sethirealty.in",  "+919820144211", :manager ],
        [ "Rohit Shah",   "rohit@sethirealty.in",  "+919820144212", :agent ]
      ].each do |name, email, mobile, role|
        user = User.across_firms.find_or_initialize_by(mobile:)
        user.assign_attributes(firm:, name:, email:, role:, status: :active)
        user.save!
      end

      unless firm.subscriptions.live.exists?
        firm.subscriptions.create!(
          plan:,
          status: :active,
          current_period_start: Date.current,
          current_period_end: Date.current + plan.period_length - 1.day,
          amount: plan.price
        )
      end

      seed_leads(firm)
      seed_bookings(firm)
      seed_inventory(firm)

      super_admin = firm.users.find_by(role: :super_admin)

      puts <<~SUMMARY

        Demo firm ready.

          Firm          #{firm.name} (#{firm.code})
          Panel         /admin/firms/#{firm.slug}
          Plan          #{plan.name} — #{plan.price_label}
          Users         #{firm.users.count} (super_admin, manager, agent)

        Sign in to the API as the super admin:

          curl -s -X POST http://localhost:3000/api/v1/auth/otp \\
            -H 'Content-Type: application/json' \\
            -d '{"mobile":"#{super_admin.mobile}"}'

        The one-time code is printed in the Rails log, not sent anywhere —
        look for the "one-time code" box, then:

          curl -s -X POST http://localhost:3000/api/v1/auth/verify \\
            -H 'Content-Type: application/json' \\
            -d '{"request_id":"<from above>","code":"<from the log>"}'

      SUMMARY
    end
  ensure
    Current.reset
  end

  # Straight from the design's LEADS constant, so the list screen has the same
  # shape of data it was drawn against — including an overdue followup, so the
  # "Missed f/u" tab isn't empty.
  def seed_leads(firm)
    return if firm.leads.any?

    agent = firm.users.find_by(role: :agent)
    manager = firm.users.find_by(role: :manager)
    sale = PropertyType.find_by(name: "Under construction")
    ready = PropertyType.find_by(name: "Ready possession")
    status = ->(name) { LeadStatus.find_by(name:) }
    source = ->(name) { LeadSource.find_by(name:) }
    typology = ->(name) { Typology.find_by(name:) }

    [
      { name: "Rhea Kapoor", mobile: "+919820144210", email: "rhea.k@example.com",
        transaction_type: "sale", property_type: sale, budget_min: 12_000_000,
        budget_max: 16_000_000, status: "Hot", source: "Portal — Housing",
        typologies: [ "3 BHK" ], next_action_at: 4.hours.from_now, assigned: agent,
        next_action_note: "Site visit confirmed, 4:30 PM" },

      { name: "Sneha Desai", mobile: "+919930371501", email: "sneha.desai@example.com",
        transaction_type: "sale", property_type: sale, budget_min: 8_500_000,
        budget_max: 11_000_000, status: "Followup", source: "Portal — 99acres",
        typologies: [ "2 BHK" ], next_action_at: 2.days.ago, assigned: agent,
        next_action_note: "Chase for documents" },

      { name: "Aditya Menon", mobile: "+919867109502", email: "a.menon@example.com",
        transaction_type: "rent", property_type: nil, budget_min: 55_000,
        budget_max: 70_000, status: "Followup", source: "Referral",
        typologies: [ "2 BHK" ], next_action_at: 1.day.from_now, assigned: manager,
        next_action_note: "Share three options" },

      { name: "Vikram Rao", mobile: "+919820144503", transaction_type: "sale",
        property_type: ready, budget_min: 11_000_000, budget_max: 13_000_000,
        status: "Negotiation", source: "Walk-in", typologies: [ "2 BHK" ],
        assigned: manager },

      { name: "Farhan Qureshi", mobile: "+919004822504", transaction_type: "sale",
        property_type: sale, budget_min: 6_000_000, budget_max: 9_500_000,
        status: "Dead", source: "Cold call", typologies: [ "1 BHK" ],
        dead_reason: "Bought through another channel partner", assigned: agent }
    ].each do |attrs|
      typology_names = attrs.delete(:typologies)
      status_name = attrs.delete(:status)
      source_name = attrs.delete(:source)
      assignee = attrs.delete(:assigned)

      lead = firm.leads.create!(
        **attrs,
        lead_status: status.call(status_name),
        lead_source: source.call(source_name),
        assigned_user: assignee
      )

      typology_names.each do |name|
        found = typology.call(name)
        lead.lead_typologies.create!(typology: found) if found
      end

      # Opening history row, the same one Leads::Create writes, so the reports
      # see these leads entering the pipeline.
      lead.lead_status_changes.create!(
        firm:, to_status: lead.lead_status, changed_at: lead.created_at
      )
    end
  end

  # The design's PROJECT_ROWS and PROPERTY_ROWS, so the index screens have the
  # same shape of data they were drawn against — including the price and area
  # bands, which are derived from the typologies rather than stored.
  def seed_inventory(firm)
    return if firm.projects.any?

    builder = ->(name) { Builder.global.find_by(name:) }
    city = ->(name) { City.find_by(name:) }
    locality = ->(name) { Locality.find_by(name:) }
    typology = ->(name) { Typology.find_by(name:) }

    [
      { name: "Aurum Vista", builder: "Aurum Developers", city: "Thane",
        locality: "Thane West", budget: 14_200_000, possession: "2027-12-01",
        brokerage: 4.5, rera: "P51700054218",
        promo: [ "Extra 1% on 3 BHK bookings till 15 Sep", 28.days.from_now.to_date ],
        typologies: { "2 BHK" => [ 14_200_000, 720 ], "3 BHK" => [ 18_000_000, 1_340 ] } },

      { name: "Nirvana Greens", builder: "Nirvana Realty", city: "Navi Mumbai",
        locality: "Kharghar", budget: 18_500_000, possession: "2028-06-01", brokerage: 4.0,
        typologies: { "2 BHK" => [ 18_500_000, 880 ], "3 BHK" => [ 24_000_000, 1_450 ] } },

      { name: "Skyline Estella", builder: "Skyline Group", city: "Navi Mumbai",
        locality: "Panvel", budget: 6_800_000, possession_label: "Ready", brokerage: 3.5,
        typologies: { "1 BHK" => [ 6_800_000, 405 ], "2 BHK" => [ 9_600_000, 730 ] } },

      { name: "Trident Bay", builder: "Trident Estates", city: "Navi Mumbai",
        locality: "Airoli", budget: 11_200_000, possession: "2027-03-01", brokerage: 4.0,
        typologies: { "2 BHK" => [ 11_200_000, 655 ] } },

      { name: "Vaayu One", builder: "Vaayu Infra", city: "Navi Mumbai",
        locality: "Ulwe", budget: 5_400_000, possession: "2027-09-01", brokerage: 5.0,
        typologies: { "1 BHK" => [ 5_400_000, 380 ], "2 BHK" => [ 7_900_000, 610 ] } }
    ].each do |row|
      project = firm.projects.create!(
        name: row[:name],
        builder: builder.call(row[:builder]),
        city: city.call(row[:city]),
        locality: locality.call(row[:locality]),
        starting_budget: row[:budget],
        possession_on: row[:possession],
        possession_label: row[:possession_label],
        brokerage_percent: row[:brokerage],
        rera_number: row[:rera],
        promo_text: row.dig(:promo, 0),
        promo_ends_on: row.dig(:promo, 1)
      )

      row[:typologies].each do |name, (price, carpet)|
        found = typology.call(name)
        next if found.nil?

        project.project_typologies.create!(
          typology: found, starting_price: price, starting_carpet_sqft: carpet
        )
      end
    end

    # Buildings are firm-owned, so these belong to this demo firm alone.
    buildings = {
      "Aurum Heights" => "Kharghar",
      "Trident Bay Towers" => "Airoli",
      "Neelkanth Apex" => "Vashi",
      "Vaayu Residency" => "Ulwe",
      "Estella Grande" => "Panvel"
    }.to_h do |name, locality_name|
      found = locality.call(locality_name)
      [ name, firm.buildings.create!(
        name:, city: found.city, locality: found,
        has_pool: [ true, false ].sample, has_gym: true
      ) ]
    end

    [
      [ "Aurum Heights", "2 BHK", "sale", 11_800_000, 690, "middle",
        "Corner flat with a wide living room and an enclosed balcony facing the garden.",
        "Owner: Mr R. Bhatt · negotiable to ₹1.14 Cr for a 45-day close · keys with the watchman." ],
      [ "Neelkanth Apex", "3 BHK", "sale", 24_500_000, 1_180, "higher",
        "High floor, sea-facing on two sides. Society fully occupied.", nil ],
      [ "Trident Bay Towers", "2 BHK", "rent", 52_000, 720, "middle",
        "Semi-furnished, available immediately.", "Owner prefers a corporate tenant." ],
      [ "Vaayu Residency", "1 BHK", "sale", 4_900_000, 405, "lower",
        "Compact and well-lit, close to the station.", nil ],
      [ "Estella Grande", "2.5 BHK", "rent", 38_000, 810, "higher",
        "Two covered parkings, gym and pool in the society.", nil ]
    ].each do |building_name, typology_name, listing_for, price, carpet, floor, description, confidential|
      found = typology.call(typology_name)
      next if found.nil?

      firm.properties.create!(
        building: buildings.fetch(building_name), typology: found,
        listing_for:, price:, carpet_area_sqft: carpet, floor_band: floor,
        description:, confidential_note: confidential,
        available_from: 1.month.from_now.to_date
      )
    end
  end

  # The design's own booking, with its exact figures — ₹1.56 Cr at 4.5% plus a
  # ₹50,000 kicker less a ₹66,000 passback, giving ₹6.86 L — so the screens have
  # something to render that matches what they were drawn against.
  def seed_bookings(firm)
    return if firm.bookings.any?

    lead = firm.leads.find_by(name: "Rhea Kapoor") || firm.leads.first
    return if lead.nil?

    manager = firm.users.find_by(role: :manager)

    booking = firm.bookings.create!(
      lead:, created_by_user: manager,
      builder_ref_no: "AV/BK/1184", unit_no: "B-1104", carpet_area_sqft: 1_340,
      customer_name: lead.name, customer_mobile: lead.mobile,
      booked_on: Date.current - 17,
      agreement_value: 15_600_000, commission_percent: 4.5,
      kicker: 50_000, passback: 66_000,
      other_details: "10:80:10 plan · two covered parkings included · floor rise waived.",
      client_paid_percent: 20
    )

    invoice = booking.invoices.create!(
      firm:, number: "INV-2026-041", issued_on: Date.current - 14,
      amount: booking.net_income, comment: "full brokerage"
    )

    booking.collections.create!(
      firm:, invoice:, received_on: Date.current, amount: 400_000,
      transaction_no: "8842190", mode: "neft_rtgs"
    )
  end

  desc "Remove the demo firm and everything under it"
  task clear: :environment do
    abort("demo:clear must never run in production") if Rails.env.production?

    Current.firm_scope_bypassed = true
    firm = Firm.find_by(slug: "sethi-realty")

    if firm
      firm.destroy!
      puts "Removed the demo firm."
    else
      puts "No demo firm to remove."
    end
  ensure
    Current.reset
  end
end
