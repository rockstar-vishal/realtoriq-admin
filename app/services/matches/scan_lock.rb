# frozen_string_literal: true

module Matches
  # One digest scan per firm. The enable rake takes these locks before it
  # flips nearby matching on, so a concurrent scan cannot notify on a
  # half-written nearby list.
  module ScanLock
    module_function

    def with(firm)
      key = key_for(firm)
      lock_key(key)
      yield
    ensure
      unlock_key(key) if key
    end

    def lock(firm)
      lock_key(key_for(firm))
    end

    def unlock(firm)
      unlock_key(key_for(firm))
    end

    def held?(firm)
      key = key_for(firm)
      high = (key >> 32) & 0xFFFFFFFF
      low = key & 0xFFFFFFFF
      connection.select_value(sql(<<~SQL.squish, high, low)).present?
        SELECT 1 FROM pg_locks
        WHERE locktype = 'advisory' AND pid = pg_backend_pid()
          AND classid = ? AND objid = ? AND objsubid = 1 AND granted
        LIMIT 1
      SQL
    end

    def key_for(firm)
      (firm.id.delete("-").to_i(16) % (1 << 62)) + 1
    end

    def lock_key(key)
      result = connection.raw_connection.exec_params("SELECT pg_advisory_lock($1::bigint)", [ Integer(key) ])
      result.clear
    end

    def unlock_key(key)
      result = connection.raw_connection.exec_params("SELECT pg_advisory_unlock($1::bigint)", [ Integer(key) ])
      result.clear
    end

    def sql(statement, *binds)
      ApplicationRecord.sanitize_sql_array([ statement, *binds ])
    end

    def connection
      ApplicationRecord.connection
    end
    private_class_method :key_for, :lock_key, :unlock_key, :sql, :connection
  end
end
