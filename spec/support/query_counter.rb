# frozen_string_literal: true

module QueryCounter
  IGNORED_SQL = /^(BEGIN|COMMIT|ROLLBACK|SAVEPOINT|RELEASE|SHOW |SET )/i

  def count_sql_queries(&)
    count = 0
    callback = lambda do |*_, payload|
      sql = payload[:sql].to_s
      next if payload[:cached]
      next if payload[:name].to_s.in?(%w[SCHEMA TRANSACTION])
      next if sql.match?(IGNORED_SQL)

      count += 1
    end

    ActiveSupport::Notifications.subscribed(callback, "sql.active_record") do
      ActiveRecord::Base.uncached(&)
    end
    count
  end
end

RSpec.configure { |config| config.include QueryCounter }
