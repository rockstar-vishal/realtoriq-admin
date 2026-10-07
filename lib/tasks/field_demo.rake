# frozen_string_literal: true

namespace :field_demo do
  desc "Flag Aarav Realty and Deshmukh Properties so their OTPs are fixed and never sent"
  task enable: :environment do
    firms = Firm.where(name: Auth::FieldDemo::FIRM_NAMES).to_a
    missing = Auth::FieldDemo::FIRM_NAMES - firms.map(&:name)
    if missing.any?
      abort("Missing #{missing.join(', ')}. Nothing was changed.")
    end
    if firms.size != Auth::FieldDemo::FIRM_NAMES.size
      abort("Expected #{Auth::FieldDemo::FIRM_NAMES.size} firms, found #{firms.size}. Nothing was changed.")
    end

    firms.each { |firm| firm.update!(field_demo: true) }
    firms.each { |firm| puts "#{firm.code} #{firm.name} users=#{firm.users.count}" }
    puts "Field demo sign-in ready"
  end
end
