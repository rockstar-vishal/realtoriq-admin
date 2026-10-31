# frozen_string_literal: true

# A creative LaunchIQ pushed for a catalog project. It has no firm: every
# broker personalises the same file with their own details. A video is a
# link, not a file, and is shared as that link.
class ProjectCreative < ApplicationRecord
  KINDS = %w[image pdf video].freeze
  PROVIDERS = %w[youtube instagram facebook google_drive].freeze

  belongs_to :project, -> { unscope(where: :firm_id) }
  has_many :personalised_creatives, -> { unscope(where: :firm_id) }, dependent: :destroy

  has_one_attached :file do |attachable|
    attachable.variant :thumb, resize_to_limit: [ 480, 480 ]
  end

  validates :external_id, presence: true, uniqueness: { scope: :project_id }
  validates :title, presence: true
  validates :kind, inclusion: { in: KINDS }
  validates :position, numericality: { only_integer: true }
  validate :media_matches_kind

  # Dates are India dates. A creative stays available through the whole of
  # its Valid Until day, and is gone the next morning.
  scope :active, -> {
    still_open = where(valid_until: nil)
    still_open.or(where(valid_until: today_ist..))
  }

  def image? = kind == "image"
  def pdf? = kind == "pdf"
  def video? = kind == "video"

  def active?
    valid_until.blank? || valid_until >= self.class.today_ist
  end

  def self.today_ist
    Time.find_zone!("Asia/Kolkata").today
  end

  private

  def media_matches_kind
    if video?
      errors.add(:video_url, "can't be blank") if video_url.blank?
      errors.add(:video_provider, "is not a video provider") unless PROVIDERS.include?(video_provider)
      errors.add(:file, "is not used for a video") if file.attached?
    elsif video_url.present?
      errors.add(:video_url, "is only used for a video")
    end
  end
end
