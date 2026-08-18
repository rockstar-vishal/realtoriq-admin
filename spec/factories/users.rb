# frozen_string_literal: true

FactoryBot.define do
  factory :user do
    firm
    name { Faker::Name.name }
    sequence(:email) { |n| "broker#{n}@example.com" }
    # Indian mobile series start at 6-9; sequence keeps them globally unique,
    # which the users.mobile index requires.
    sequence(:mobile) { |n| "+9198#{format('%08d', 20_000_000 + n)}" }
    role { :agent }
    status { :active }

    trait :super_admin do
      role { :super_admin }
    end

    trait :manager do
      role { :manager }
    end

    trait :disabled do
      status { :disabled }
    end

    trait :locked_out do
      otp_locked_until { 30.minutes.from_now }
    end
  end

  factory :contact_channel do
    firm
    kind { :email }
    sequence(:value) { |n| "firm#{n}@example.com" }

    trait :email do
      kind { :email }
      sequence(:value) { |n| "firm#{n}@example.com" }
    end

    trait :mobile do
      kind { :mobile }
      sequence(:value) { |n| "+9199#{format('%08d', 30_000_000 + n)}" }
    end

    trait :whatsapp do
      kind { :whatsapp }
      sequence(:value) { |n| "+9197#{format('%08d', 40_000_000 + n)}" }
    end

    trait :verified do
      verification_state { :verified }
      verified_at { Time.current }
    end
  end
end
