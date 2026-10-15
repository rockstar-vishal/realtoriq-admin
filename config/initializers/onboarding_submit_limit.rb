# frozen_string_literal: true

# Middleware is built before Zeitwerk will resolve a constant. Requiring
# onboarding.rb here also matters: submit_limit defines the Onboarding module,
# and once that constant exists Zeitwerk will not load app/services/onboarding.rb
# on its own, so the registration constants would be missing.
files = [
  Rails.root.join("app/services/onboarding.rb"),
  Rails.root.join("app/services/onboarding/submit_limit.rb")
]
Rails.autoloaders.main.ignore(*files)
files.each { |path| require path }

Rails.application.config.middleware.unshift Onboarding::SubmitLimit
