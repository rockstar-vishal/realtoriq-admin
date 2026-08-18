# frozen_string_literal: true

FactoryBot.define do
  factory :plan do
    sequence(:name) { |n| "Growth #{n}" }
    price { 2_499 }
    interval { "month" }
    max_devices { 3 }
    active { true }
  end

  factory :subscription do
    firm
    plan
    status { :active }
    current_period_start { Date.current }
    current_period_end { Date.current + 1.month - 1.day }
    amount { 2_499 }

    trait :expired do
      current_period_start { 2.months.ago.to_date }
      current_period_end { 1.day.ago.to_date }
    end

    trait :cancelled do
      status { :cancelled }
      cancelled_at { Time.current }
      cancel_reason { "Switched to a competitor" }
    end
  end
end
