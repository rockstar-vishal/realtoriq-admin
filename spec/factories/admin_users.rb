# frozen_string_literal: true

FactoryBot.define do
  factory :admin_user do
    name { "Ops Person" }
    sequence(:email) { |n| "ops#{n}@realtoriq.in" }
    password { "correct-horse-battery" }
    active { true }

    trait :deactivated do
      active { false }
    end
  end
end
