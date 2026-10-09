# frozen_string_literal: true

# Presence of a row turns nearby matching on for every firm. Created by
# `bin/rails matches:nearby_enable` after centers exist and digests have been
# rewritten without a notification.
class NearbyMatching < ApplicationRecord
  def self.enabled?
    exists?
  end

  def self.enable!
    return if enabled?

    create!(enabled_at: Time.current)
  end
end
