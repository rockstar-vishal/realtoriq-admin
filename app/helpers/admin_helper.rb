# frozen_string_literal: true

module AdminHelper
  # Highlights the nav item for the section you're in, not just the exact page,
  # so /admin/firms/acme still lights up "Firms".
  def current_page_section?(path)
    section = path.to_s.split("?").first
    request.path == section || request.path.start_with?("#{section}/")
  end

  FIRM_STATUS_TAGS = {
    "active" => "tag-accent",
    "pending" => "tag-neutral",
    "suspended" => "tag-solid",
    "churned" => "tag-neutral"
  }.freeze

  def firm_status_tag(firm)
    tag.span(firm.status.humanize, class: "tag #{FIRM_STATUS_TAGS.fetch(firm.status, 'tag-neutral')}")
  end

  # The three channel pills on the firms index. Verified reads in the accent
  # ramp; everything else stays neutral so the eye goes to what's missing.
  def channel_tag(channel)
    label = channel.kind == "whatsapp" ? "WA" : channel.kind.first(3).upcase
    klass = channel.verified? ? "tag-accent" : "tag-neutral"

    tag.span(label, class: "tag #{klass}", title: "#{channel.kind.humanize}: #{channel.verification_state}")
  end

  TRAINING_STATUS_TAGS = {
    "draft" => "tag-neutral",
    "active" => "tag-accent",
    "archived" => "tag-solid"
  }.freeze

  def training_status_tag(training)
    label = training.active? && training.expired? ? "Expired" : training.status.humanize
    tag.span(label, class: "tag #{TRAINING_STATUS_TAGS.fetch(training.status, 'tag-neutral')}")
  end

  def blank_dash(value)
    value.presence || tag.span("—", class: "text-[var(--color-neutral-500)]")
  end

  # ₹ amounts are stored as whole rupees. Indian digit grouping (1,23,45,678)
  # is not what delimiter: "," gives you, so group by hand.
  def rupees(amount)
    return blank_dash(nil) if amount.blank?

    digits = amount.to_i.abs.to_s
    grouped =
      if digits.length <= 3
        digits
      else
        head, tail = digits[0..-4], digits[-3..]
        head = head.reverse.scan(/\d{1,2}/).join(",").reverse
        "#{head},#{tail}"
      end

    "#{'-' if amount.to_i.negative?}₹#{grouped}"
  end
end
