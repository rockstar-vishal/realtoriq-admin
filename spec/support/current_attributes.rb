# frozen_string_literal: true

# CurrentAttributes are reset by the Rails executor per request, but nothing
# resets them between RSpec examples. Without this, a Current.firm set in one
# example leaks into the next and the isolation specs would pass for the wrong
# reason.
RSpec.configure do |config|
  config.before { Current.reset }
  config.after  { Current.reset }
end
