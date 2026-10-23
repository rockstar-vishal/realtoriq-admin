# frozen_string_literal: true

module Inventory
  # A project is Ready possession when its possession month is this month in
  # India, at most two months ahead, or any past month. A label with no date
  # that starts with the word Ready, such as "Ready to move", counts as ready.
  class PossessionMatch
    WINDOW = 2

    def self.ready?(project, on: nil)
      today = on || Time.find_zone(Lead::NCD_ZONE).today
      if project.possession_on.present?
        return within?(project.possession_on, today)
      end
      return true if ready_label?(project.possession_label)

      parsed = parse_label(project.possession_label)
      parsed.present? && within?(parsed, today)
    end

    def self.match_label(project)
      "Sale · #{ready?(project) ? 'Ready possession' : 'Under construction'}"
    end

    def self.within?(date, today)
      index = date.year * 12 + date.month
      now = today.year * 12 + today.month
      index - now <= WINDOW
    end

    def self.ready_label?(label)
      label.to_s.strip.match?(/\Aready\b/i)
    end

    def self.parse_label(label)
      text = label.to_s.strip
      return if text.blank? || ready_label?(text)

      [ "%b %Y", "%B %Y" ].each do |format|
        return Date.strptime(text, format)
      rescue Date::Error
        next
      end
      nil
    end

    private_class_method :within?, :ready_label?, :parse_label
  end
end
