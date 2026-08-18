# frozen_string_literal: true

FactoryBot.define do
  factory :city do
    sequence(:name) { |n| "City #{n}" }
    state { "Maharashtra" }
  end

  factory :locality do
    city
    sequence(:name) { |n| "Locality #{n}" }
    pincode { "410210" }
  end

  factory :firm do
    sequence(:name) { |n| "Sethi Realty #{n}" }
    legal_name { "#{name} Pvt Ltd" }
    status { :active }
    primary_contact_name { Faker::Name.name }
    rera_number { "A#{Faker::Number.number(digits: 11)}" }

    trait :pending do
      status { :pending }
      activated_at { nil }
    end

    trait :suspended do
      status { :suspended }
      suspended_at { Time.current }
      suspension_reason { "Payment overdue for 60 days" }
    end

    trait :with_super_admin do
      after(:create) { |firm| create(:user, :super_admin, firm:) }
    end

    trait :with_channels do
      after(:create) do |firm|
        create(:contact_channel, :email, firm:)
        create(:contact_channel, :mobile, firm:)
        create(:contact_channel, :whatsapp, firm:)
      end
    end
  end

  factory :firm_bank_account do
    firm
    account_number { Faker::Number.number(digits: 14).to_s }
    ifsc { "HDFC0001234" }
    bank_name { "HDFC Bank" }
    holder_name { Faker::Name.name }
  end
end
