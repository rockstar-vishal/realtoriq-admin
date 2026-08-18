# frozen_string_literal: true

module Admin
  # Backs the create/edit firm screen, which writes to five models at once: the
  # firm, its three contact channels, its super_admin, and its first
  # subscription — the last three on create only.
  #
  # A form object rather than nested attributes because the shapes don't line
  # up: the view collects one email/mobile/WhatsApp trio that becomes three
  # ContactChannel rows, and the owner and plan fields exist only when creating.
  # Doing that through accepts_nested_attributes_for would mean more
  # indirection, not less.
  #
  # Creating covers the whole onboarding in one screen deliberately. Leaving the
  # plan and activation to separate visits meant a firm could be created that
  # looked finished but whose broker got `subscription_lapsed` on first sign-in.
  class FirmForm
    include ActiveModel::Model

    FIRM_FIELDS = %i[
      name legal_name code slug primary_contact_name
      rera_number rera_valid_till pan gst_number
      address_line1 address_line2 city_id locality_id pincode internal_notes
    ].freeze

    CONTACT_FIELDS = %i[contact_email contact_mobile contact_whatsapp whatsapp_same_as_mobile].freeze
    OWNER_FIELDS = %i[owner_name owner_email owner_mobile].freeze
    SUBSCRIPTION_FIELDS = %i[plan_id subscription_starts_on activate_immediately].freeze

    attr_accessor(*FIRM_FIELDS, *CONTACT_FIELDS, *OWNER_FIELDS, *SUBSCRIPTION_FIELDS, :logo)
    attr_reader :firm

    validates :name, presence: true
    validates :contact_email, presence: true
    validates :contact_mobile, presence: true
    with_options if: :creating? do
      validates :owner_name, presence: true
      validates :owner_mobile, presence: true
    end

    # Required only when creating, and only once a plan exists to pick — a
    # brand-new installation can still onboard its first firm before anyone has
    # priced anything.
    #
    # Deliberately outside the with_options block: an inner `if:` REPLACES the
    # one with_options injects rather than combining with it, so nesting this
    # would silently drop the creating? half and demand a plan on every edit.
    validates :plan_id, presence: true, if: -> { creating? && Plan.active.exists? }

    # Lets form_with build /admin/firms paths and firm[...] field names.
    def self.model_name = ActiveModel::Name.new(self, nil, "Firm")

    def initialize(firm = Firm.new, attributes = nil)
      @firm = firm
      # Captured up front, not derived from firm.persisted? on demand: save
      # persists the firm before the owner is created, so a lazy check would
      # flip to false mid-save and silently skip creating the super admin.
      @creating = !firm.persisted?
      load_from_record
      assign_attributes(attributes) if attributes.present?
    end

    def creating? = @creating

    def persisted? = firm.persisted?

    def to_param = firm.slug

    def save
      return false unless valid?

      Firm.transaction do
        apply_firm_attributes
        firm.save!
        sync_contact_channels

        if creating?
          create_super_admin
          create_subscription
          activate_firm if activating?
        end
      end

      true
    rescue ActiveRecord::RecordInvalid => e
      absorb_errors(e.record)
      false
    end

    private

    def load_from_record
      FIRM_FIELDS.each { |field| public_send("#{field}=", firm.public_send(field)) }

      if creating?
        # Sensible defaults so the common path is one pass down the form: the
        # cheapest active plan, starting today, live immediately.
        self.plan_id = Plan.active.ordered.first&.id
        self.subscription_starts_on = Date.current
        self.activate_immediately = true
        return
      end

      channels = firm.contact_channels.index_by(&:kind)
      self.contact_email = channels["email"]&.value
      self.contact_mobile = channels["mobile"]&.value
      self.contact_whatsapp = channels["whatsapp"]&.value
    end

    def apply_firm_attributes
      FIRM_FIELDS.each { |field| firm.public_send("#{field}=", public_send(field)) }
      firm.logo.attach(logo) if logo.present?
    end

    # Upserts the three channels. Changing a channel's value resets its
    # verification — a newly typed number has not been proven, and silently
    # keeping the old green badge would be a lie.
    def sync_contact_channels
      {
        "email" => contact_email,
        "mobile" => contact_mobile,
        "whatsapp" => whatsapp_value
      }.each do |kind, value|
        channel = firm.contact_channels.find_or_initialize_by(kind:)

        if value.blank?
          channel.destroy if channel.persisted?
          next
        end

        # Normalise before assigning so value_changed? compares like with like —
        # otherwise retyping the same number in a different format would read as
        # a change and clear a badge the firm has already earned.
        channel.value = ContactChannel.normalise_value(kind:, value:)
        channel.reset_verification if channel.persisted? && channel.value_changed?
        channel.save!
      end

      firm.contact_channels.reload
    end

    def whatsapp_value
      ActiveModel::Type::Boolean.new.cast(whatsapp_same_as_mobile) ? contact_mobile : contact_whatsapp
    end

    def create_super_admin
      firm.users.create!(
        name: owner_name,
        email: owner_email.presence,
        mobile: owner_mobile,
        role: :super_admin,
        status: :active
      )
    end

    def create_subscription
      plan = Plan.active.find_by(id: plan_id)
      return if plan.nil?

      starts_on = parsed_start_date

      firm.subscriptions.create!(
        plan:,
        status: :active,
        current_period_start: starts_on,
        current_period_end: starts_on + plan.period_length - 1.day,
        # Snapshot, so a later price change never rewrites this firm's history.
        amount: plan.price,
        created_by_admin: Current.admin_user
      )
    end

    def parsed_start_date
      Date.parse(subscription_starts_on.to_s)
    rescue Date::Error, TypeError
      Date.current
    end

    def activating? = ActiveModel::Type::Boolean.new.cast(activate_immediately)

    def activate_firm
      firm.update!(status: :active, activated_at: Time.current)
    end

    # Surfaces a failure from firm/channel/user on the matching form field, so
    # the view shows it next to the input the admin actually typed into.
    def absorb_errors(record)
      case record
      when Firm
        record.errors.each { |error| errors.add(error.attribute, error.message) }
      when ContactChannel
        field = "contact_#{record.kind}".to_sym
        record.errors.each { |error| errors.add(field, error.message) }
      when User
        record.errors.each do |error|
          mapped = { name: :owner_name, email: :owner_email, mobile: :owner_mobile }[error.attribute]
          errors.add(mapped || :base, error.message)
        end
      when Subscription
        record.errors.each { |error| errors.add(:plan_id, error.message) }
      else
        errors.add(:base, record.errors.full_messages.to_sentence)
      end
    end
  end
end
