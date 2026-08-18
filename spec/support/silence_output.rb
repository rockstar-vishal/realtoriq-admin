# frozen_string_literal: true

# Seed and rake tasks print progress for the human running them. That's useful
# at a terminal and pure noise in a spec run, so silence it here rather than
# putting `unless Rails.env.test?` guards through operational code.
RSpec.configure do |config|
  config.around(:each, :silence_output) do |example|
    original = $stdout
    $stdout = StringIO.new
    begin
      example.run
    ensure
      $stdout = original
    end
  end
end
