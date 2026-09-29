# frozen_string_literal: true

module Trainings
  # Enqueued by Training#activate!, on the first publication only.
  class AnnounceJob < ApplicationJob
    def perform(training_id)
      training = Training.find_by(id: training_id)
      return if training.nil?

      Announce.call(training:)
    end
  end
end
