# frozen_string_literal: true

# A course published by KGen ops and read by every broker on the platform: a
# banner, a PDF guide, an intro, and a podcast.
#
# Deliberately global. There is no firm_id, so FirmScoped does not apply and the
# tenancy guard spec needs no exemption — it only polices models that carry the
# column. Same family as City: one list, ops-maintained, seen by everyone.
class Training < ApplicationRecord
  LANGUAGES = %w[hinglish en mr].freeze
  # "Hinglish" is what brokers call it, and "En"/"Mr" would read as nonsense on
  # a dropdown, so the labels are spelled out rather than humanized.
  LANGUAGE_LABELS = { "hinglish" => "Hinglish", "en" => "English", "mr" => "Marathi" }.freeze
  STATUSES = %w[draft active archived].freeze

  # Ops upload straight from the admin panel, so UploadPurpose — which guards
  # the broker API's ticket flow — never sees these files. The caps live here
  # instead, on the model, so a console upload is held to them too.
  LIMITS = {
    banner: { max_bytes: 2.megabytes, content_types: %w[image/png image/jpeg image/webp] },
    document: { max_bytes: 10.megabytes, content_types: %w[application/pdf] },
    podcast: { max_bytes: 40.megabytes, content_types: %w[audio/mpeg audio/mp4 audio/aac audio/x-m4a] }
  }.freeze

  belongs_to :created_by_admin_user, class_name: "AdminUser", optional: true

  # Only ever reachable for a draft: a published training is archived, never
  # destroyed, so no broker's notes disappear underneath them.
  has_many :training_notes, dependent: :destroy

  has_one_attached :banner
  has_one_attached :document
  has_one_attached :podcast

  enum :status, STATUSES.index_by(&:itself), validate: true
  enum :language, LANGUAGES.index_by(&:itself), validate: true, prefix: :language

  validates :title, :description, :intro_text, presence: true
  validates :podcast_duration_seconds,
    numericality: { only_integer: true, greater_than: 0 }, allow_nil: true
  validates :podcast_url,
    format: { with: %r{\Ahttps://\S+\z}, message: "must be an https:// link" }, allow_blank: true
  validate :attachments_are_within_limits

  # Newest first, always. By publication rather than by the last edit, so fixing
  # a typo on a live training does not jump it above the other one; a draft has
  # no publication date and sorts by when it was written.
  scope :newest_first, lambda {
    order(Arel.sql("COALESCE(published_at, created_at) DESC"), id: :desc)
  }

  # What a broker may see. Dates are compared in IST (config.time_zone) and the
  # last day counts: a training valid upto 31 March is readable all day on the
  # 31st and gone on 1 April.
  scope :live, -> { active.where("valid_upto IS NULL OR valid_upto >= ?", Date.current) }

  def language_label = LANGUAGE_LABELS.fetch(language, language.to_s.humanize)

  def expired? = valid_upto.present? && valid_upto < Date.current

  def podcast_ready? = podcast.attached? || podcast_url.present?

  # A row that has never been published carries nobody's notes and nothing a
  # broker has seen, so ops may remove it outright. Everything else archives.
  def deletable? = draft? && published_at.nil?

  def created_by_name = created_by_admin_user&.display_name

  # Everything ops still have to supply before this can go live. The admin
  # screen lists them; activate! refuses while any remain.
  def activation_blockers
    blockers = []
    blockers << "a title" if title.blank?
    blockers << "a description" if description.blank?
    blockers << "the intro text" if intro_text.blank?
    blockers << "a banner image" unless banner.attached?
    blockers << "the PDF guide" unless document.attached?
    blockers << "a podcast file or link" unless podcast_ready?
    blockers << "a valid-upto date that has not passed" if expired?
    blockers
  end

  def activate!(actor: nil)
    blockers = activation_blockers
    if blockers.any?
      errors.add(:base, "Still needs #{blockers.to_sentence}.")
      return false
    end

    first_publication = published_at.nil?
    update!(status: "active", published_at: published_at || Time.current)
    AuditEvent.record!(subject: self, actor:, action: "training.activated",
                       metadata: { first_publication: })
    # Announced once, on the first publication. Archiving and activating again
    # is a correction, not news — and the dedupe key would swallow it anyway.
    Trainings::AnnounceJob.perform_later(id) if first_publication
    true
  end

  def archive!(actor: nil)
    update!(status: "archived")
    AuditEvent.record!(subject: self, actor:, action: "training.archived")
    true
  end

  private

  # Rails ships no attachment validation. Checked on save rather than in the
  # controller so every write path is held to the same limits.
  def attachments_are_within_limits
    LIMITS.each do |name, rules|
      attachment = public_send(name)
      next unless attachment.attached?

      blob = attachment.blob
      next if blob.nil?

      if blob.byte_size.to_i > rules[:max_bytes]
        errors.add(name, "must be #{rules[:max_bytes] / 1.megabyte} MB or smaller")
      end

      unless rules[:content_types].include?(blob.content_type.to_s)
        errors.add(name, "must be #{rules[:content_types].join(', ')}")
      end
    end
  end
end
