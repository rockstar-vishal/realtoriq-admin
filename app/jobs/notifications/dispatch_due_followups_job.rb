# frozen_string_literal: true

module Notifications
  # Scheduled every minute on staging and production. Development has no queue
  # database; run Notifications::DispatchDueFollowups.call from a console there.
  class DispatchDueFollowupsJob < ApplicationJob
    def perform
      DispatchDueFollowups.call
    end
  end
end
