# frozen_string_literal: true

# Presence of a row turns anchor matching on for every firm. The radius lives
# on that row. Created by `bin/rails matches:anchor_enable`. No row means off,
# and matching stays as it is today apart from shown distances.
class AnchorMatching < ApplicationRecord
  def self.enabled?
    exists?
  end

  # Nil while the switch is off. Callers that also need the flag read this
  # once: a nil radius is the off switch.
  def self.radius_m
    pick(:radius_m)
  end

  def self.enable!
    return if enabled?

    create!(enabled_at: Time.current)
  end

  def self.disable!
    delete_all
  end

  def self.set_radius!(metres)
    row = first
    raise ArgumentError, "Anchor matching is off" unless row

    row.update!(radius_m: metres)
  end
end
