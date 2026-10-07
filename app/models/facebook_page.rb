# frozen_string_literal: true

# A Meta Page granted to this firm. page_id is unique across every firm.
# The firm holds it only while the row has a Page token or subscribed is
# true. A stale row can be released. Cross-firm checks use across_firms.
class FacebookPage < ApplicationRecord
  include FirmScoped

  STATUSES = %w[active unsubscribed error].freeze

  enum :status, STATUSES.index_by(&:itself), prefix: :page, validate: true, default: :unsubscribed

  encrypts :page_access_token

  belongs_to :facebook_connection, -> { unscope(where: :firm_id) }
  belongs_to_same_firm :facebook_connection
  has_many :facebook_lead_forms, -> { unscope(where: :firm_id) }, dependent: :destroy
  has_many :facebook_lead_imports, -> { unscope(where: :firm_id) }, dependent: :destroy

  validates :page_id, :page_name, presence: true
  validate :page_id_is_globally_unique

  scope :subscribed, -> { where(subscribed: true) }
  # Held: still connected. Stale: no token and not subscribed, so another
  # firm may take the Page.
  scope :held, -> { where("subscribed = TRUE OR page_access_token IS NOT NULL") }
  scope :stale, -> { where(subscribed: false, page_access_token: nil) }

  FormListing = Struct.new(
    :form_id, :form_name, :state, :record, :meta_status, keyword_init: true
  )

  def subscribe!
    update!(
      subscribed: true,
      subscribed_at: subscribed_at || Time.current,
      status: :active,
      status_message: nil
    )
  end

  def unsubscribe!
    update!(subscribed: false, status: :unsubscribed, status_message: nil)
  end

  def held?
    subscribed? || page_access_token.present?
  end

  # Last sync, joined to the forms this firm owns.
  def form_listings
    catalog_entries = Array(form_catalog).map { |entry| entry.stringify_keys }
    catalog_by_id = catalog_entries.index_by { |entry| entry["form_id"].to_s }
    owned = facebook_lead_forms.to_a
    ids = (catalog_by_id.keys + owned.map(&:form_id)).uniq
    claimed = if ids.empty?
      {}
    else
      FacebookLeadForm.across_firms.where(form_id: ids).index_by(&:form_id)
    end

    ids.filter_map { |form_id| listing_for(form_id, catalog_by_id[form_id], claimed[form_id]) }
      .sort_by { |listing| [ listing_sort_key(listing.state), listing.form_name.to_s.downcase ] }
  end

  def catalog_entry_for(meta_form_id)
    Array(form_catalog).map { |entry| entry.stringify_keys }
      .find { |entry| entry["form_id"].to_s == meta_form_id.to_s }
  end

  private

  def listing_for(form_id, meta, row)
    return if row && row.firm_id != firm_id

    state = row.nil? ? :available : :mapped
    name = if state == :mapped
      row.form_name.presence || meta&.dig("form_name").presence || "Form #{form_id}"
    else
      meta&.dig("form_name").presence || "Form #{form_id}"
    end

    FormListing.new(
      form_id:,
      form_name: name,
      state:,
      record: (row if state == :mapped),
      meta_status: meta&.dig("status")
    )
  end

  def page_id_is_globally_unique
    return if page_id.blank?

    scope = self.class.across_firms.where(page_id:)
    scope = scope.where.not(id:) if persisted?
    errors.add(:page_id, "has already been taken") if scope.exists?
  end

  def listing_sort_key(state)
    state == :mapped ? 0 : 1
  end
end
