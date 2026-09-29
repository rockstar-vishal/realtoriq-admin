# frozen_string_literal: true

module Trainings
  # Tells every broker on the platform that a training has gone live.
  #
  # A service called from a job, never from the controller: Notifications::Record
  # pushes inline, so a few thousand brokers would hold the admin's activate
  # request open for minutes and time out halfway through.
  #
  # Runnable from a console:
  #   Trainings::Announce.call(training: Training.find(id))
  class Announce
    Result = Struct.new(:ok?, :notified, keyword_init: true)

    def self.call(...) = new(...).call

    def initialize(training:)
      @training = training
    end

    def call
      return Result.new(ok?: true, notified: 0) unless training.active?

      notified = 0
      recipients.find_each { |user| notified += 1 if notify(user) }
      Result.new(ok?: true, notified:)
    end

    private

    attr_reader :training

    # Active brokers in firms that are themselves active. A suspended firm's
    # users cannot sign in, so a row in their inbox is noise nobody reads.
    # across_firms because this walks every tenant with no Current.firm set.
    def recipients
      User.across_firms.active
        .joins(:firm).where(firms: { status: "active" })
        .includes(:firm)
    end

    def notify(user)
      result = Current.set(firm: user.firm, user:) do
        Notifications::Record.call(
          user:,
          kind: "training_published",
          title: "New training: #{training.title}",
          body: training.description.to_s.truncate(120),
          # One row per broker per training, whatever happens afterwards:
          # archiving and activating again must not announce it twice.
          dedupe_key: "training_published:#{training.id}",
          data: { "page" => "skills-training", "item" => training.id }
        )
      end
      result.created
    end
  end
end
