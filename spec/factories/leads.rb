# frozen_string_literal: true

FactoryBot.define do
  factory :lead_status do
    sequence(:name) { |n| "Status #{n}" }
    sequence(:sort_order)

    trait :new_lead do
      name { "New" }
      sort_order { 0 }
    end

    trait :dead do
      name { "Dead" }
      is_dead { true }
      is_terminal { true }
    end

    trait :booked do
      name { "Booked" }
      is_booked { true }
      is_terminal { true }
    end
  end

  factory :lead_source do
    sequence(:name) { |n| "Source #{n}" }
    category { "portal" }
  end

  factory :property_type do
    sequence(:name) { |n| "Property type #{n}" }
  end

  factory :typology do
    sequence(:name) { |n| "#{n} BHK" }
    bedrooms { 2.0 }
  end

  factory :lead do
    firm
    lead_status
    sequence(:name) { |n| "Lead #{n}" }
    sequence(:mobile) { |n| "+9198#{format('%08d', 70_000_000 + n)}" }
    transaction_type { "sale" }
    property_type
    budget_min { 10_000_000 }
    budget_max { 15_000_000 }

    trait :rent do
      transaction_type { "rent" }
      property_type { nil }
      budget_min { 50_000 }
      budget_max { 70_000 }
    end

    trait :overdue do
      next_action_at { 2.days.ago }
    end

    trait :upcoming do
      next_action_at { 2.days.from_now }
    end
  end

  factory :lead_activity do
    firm
    lead
    kind { "call" }
    body { "Spoke about the 3 BHK" }
    occurred_at { Time.current }
  end
end

FactoryBot.define do
  factory :builder do
    sequence(:name) { |n| "Builder #{n}" }
    firm { nil }
  end

  factory :building do
    firm
    city
    locality { association :locality, city: }
    sequence(:name) { |n| "Aurum Heights #{n}" }
  end

  factory :project do
    firm
    sequence(:name) { |n| "Aurum Vista #{n}" }
    builder
    city
    starting_budget { 14_200_000 }
    possession_on { 18.months.from_now.to_date }
  end

  factory :property do
    firm
    building { association :building, firm: }
    typology
    listing_for { "sale" }
    price { 11_800_000 }
    carpet_area_sqft { 690 }
  end
end

FactoryBot.define do
  factory :project_typology do
    project
    typology
    starting_price { 14_200_000 }
    starting_carpet_sqft { 720 }
  end
end

FactoryBot.define do
  factory :booking do
    firm
    lead { association :lead, firm: }
    booked_on { Date.current }
    agreement_value { 15_600_000 }
    commission_percent { 4.5 }
    kicker { 50_000 }
    passback { 66_000 }
    customer_name { "Rhea Kapoor" }
    sequence(:customer_mobile) { |n| "+9198#{format('%08d', 60_000_000 + n)}" }

    trait :cancelled do
      status { "cancelled" }
      cancelled_at { Time.current }
      cancellation_reason { "Client withdrew" }
    end
  end

  factory :invoice do
    firm
    booking { association :booking, firm: }
    sequence(:number) { |n| "INV-2026-#{format('%03d', n)}" }
    issued_on { Date.current }
    amount { 100_000 }
  end

  factory :collection do
    firm
    booking { association :booking, firm: }
    received_on { Date.current }
    amount { 50_000 }
    mode { "neft_rtgs" }
  end
end
