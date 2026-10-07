# frozen_string_literal: true

namespace :review_demo do
  desc "Create or refresh the Meta review demo firm (safe in production)"
  task setup: :environment do
    firm = nil
    ActiveRecord::Base.transaction do
      firm = prepare_review_demo_firm
    end
    puts firm.code
    puts "Review sign-in ready"
  ensure
    Current.reset
  end

  desc "Disconnect Facebook, drop leads and Page rows, and recreate sample data"
  task reset: :environment do
    ActiveRecord::Base.transaction do
      reset_review_demo_firm
    end
  ensure
    Current.reset
  end
end

def prepare_review_demo_firm
  existing = User.across_firms.find_by(mobile: Auth::ReviewLogin::MOBILE)
  if existing && !existing.firm&.review_demo?
    abort("#{existing.firm.code} already uses the review mobile. Nothing was changed.")
  end

  masters = review_demo_masters
  firm = Firm.find_or_initialize_by(slug: "realtoriq-review-demo")
  firm.assign_attributes(
    name: "RealtorIQ Demo",
    review_demo: true,
    status: :active,
    activated_at: firm.activated_at || Time.current,
    city: masters[:city],
    locality: masters[:locality],
    pan: nil,
    gst_number: nil,
    rera_number: nil
  )
  firm.save!
  Current.firm = firm

  ensure_review_subscription!(firm, masters[:plan])
  user = ensure_review_user!(firm)
  seed_review_demo_sample!(firm, user, masters)
  firm
end

def reset_review_demo_firm
  firm = Firm.find_by(review_demo: true)
  abort("No review demo firm.") if firm.nil?

  Current.firm = firm
  actor = firm.users.find_by!(role: :super_admin)
  FacebookConnection.across_firms.where(firm_id: firm.id).where.not(status: "disconnected").find_each do |connection|
    Facebook::Disconnect.call(connection:, actor:)
  end
  # Same order as Firm's dependent deletes: imports, forms, then pages.
  firm.facebook_lead_imports.delete_all
  firm.facebook_lead_forms.delete_all
  firm.facebook_pages.delete_all
  firm.leads.find_each(&:destroy!)
  seed_review_demo_sample!(firm, actor, review_demo_masters)
end

def ensure_review_subscription!(firm, plan)
  return if firm.subscriptions.live.exists?

  starts_on = Date.current
  firm.subscriptions.create!(
    plan:,
    status: :active,
    current_period_start: starts_on,
    current_period_end: starts_on + 12.months - 1.day,
    amount: plan.price
  )
end

def ensure_review_user!(firm)
  user = User.across_firms.find_or_initialize_by(mobile: Auth::ReviewLogin::MOBILE)
  user.assign_attributes(
    firm:,
    name: "Meta Reviewer",
    role: :super_admin,
    status: :active,
    email: nil,
    failed_otp_attempts: 0,
    otp_locked_until: nil
  )
  user.save!
  user
end

def seed_review_demo_sample!(firm, actor, masters)
  seed_review_projects!(firm, masters) if firm.projects.none?
  seed_review_leads!(firm, actor, masters) if firm.leads.none?
end

def seed_review_projects!(firm, masters)
  [ "Sample Project 1", "Sample Project 2" ].each do |name|
    result = Inventory::CreateProject.new(
      firm:,
      attributes: {
        name:,
        builder: masters[:builder],
        city: masters[:city],
        locality: masters[:locality],
        starting_budget: 8_000_000,
        possession_label: "Ready"
      },
      typologies: [
        { typology_id: masters[:typology].id, starting_price: 8_000_000, starting_carpet_sqft: 700 }
      ]
    ).call
    next if result.ok?

    message = result.error_message.presence || result.errors&.full_messages&.to_sentence || "Could not create #{name}"
    raise message
  end
end

def seed_review_leads!(firm, actor, masters)
  5.times do |index|
    number = index + 1
    result = Leads::Create.new(
      firm:,
      actor:,
      attributes: {
        name: "Sample Lead #{number}",
        mobile: format("+91910000000%d", number),
        transaction_type: "sale",
        property_type_id: masters[:property_type].id,
        lead_source_id: masters[:lead_source].id,
        budget: 8_000_000
      },
      typology_ids: [ masters[:typology].id ],
      locality_ids: [ masters[:locality].id ]
    ).call
    raise result.error_message.presence || "Could not create Sample Lead #{number}" unless result.ok?
  end
end

def review_demo_masters
  city = City.find_by!(name: "Mumbai")
  locality = Locality.find_by!(city:, name: "Kharghar")
  plan = Plan.active.find_by(name: "Growth") || Plan.active.ordered.first
  builder = Builder.global.order(:name).first
  typology = Typology.order(:name).first
  property_type = PropertyType.active.ordered.first
  lead_source = LeadSource.order(:name).first
  missing = []
  missing << "an active plan" if plan.nil?
  missing << "a builder" if builder.nil?
  missing << "a typology" if typology.nil?
  missing << "a property type" if property_type.nil?
  missing << "a lead source" if lead_source.nil?
  abort("Run bin/rails db:seed first — missing #{missing.join(', ')}.") if missing.any?

  { city:, locality:, plan:, builder:, typology:, property_type:, lead_source: }
end
