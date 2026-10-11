# frozen_string_literal: true

# Loaded by hand because middleware is built before Zeitwerk will resolve a
# constant from app/services. The cookie domain is left unset: a domain of
# .realtoriq.kgen.tech would send the admin session to every firm site.
ignored = %w[host host_lock host_constraint].map { |name| Rails.root.join("app/services/sites/#{name}.rb") }
Rails.autoloaders.main.ignore(*ignored)
ignored.each { |path| require path }

Rails.application.config.middleware.use Sites::HostLock
