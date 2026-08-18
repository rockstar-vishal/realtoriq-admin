# frozen_string_literal: true

# UUIDv7 (RFC 9562) — time-ordered UUIDs, generated in Ruby.
#
# Every table in this app uses UUID primary keys. v7 rather than v4 because the
# leading 48 bits are a millisecond timestamp, so ids sort in creation order and
# B-tree inserts stay at the right-hand edge of the index instead of scattering
# across it the way random v4 keys do.
#
# Postgres 14 has no native uuidv7(); Postgres 18 does. Migrations still declare
# `gen_random_uuid()` as the column default so a row inserted outside Rails gets
# a valid (if unordered) key, and ApplicationRecord overrides it with a v7 value
# on create. When this app moves to Postgres 18 the default can take over and
# this generator becomes redundant — the wire format is identical either way.
#
# Layout (128 bits):
#    48  unix timestamp, milliseconds
#     4  version (0b0111)
#    12  counter, monotonic within a millisecond
#     2  variant (0b10)
#    62  random
module UuidV7
  MAX_COUNTER = 0xFFF

  # Initialised at load time, not lazily — `@mutex ||= Mutex.new` inside
  # generate would itself be a race on the very first concurrent call.
  @mutex = Mutex.new
  @last_ms = 0
  @counter = 0

  class << self
    def generate
      ms, counter = next_tick

      value = (ms & 0xFFFF_FFFF_FFFF) << 80
      value |= 0x7 << 76
      value |= (counter & MAX_COUNTER) << 64
      value |= 0b10 << 62
      value |= SecureRandom.random_number(1 << 62)

      hex = value.to_s(16).rjust(32, "0")
      "#{hex[0, 8]}-#{hex[8, 4]}-#{hex[12, 4]}-#{hex[16, 4]}-#{hex[20, 12]}"
    end

    private

    # Returns the [timestamp, counter] pair for the next id, holding a lock so
    # concurrent threads can't be handed the same one.
    def next_tick
      @mutex.synchronize do
        now = current_ms

        if now > @last_ms
          @last_ms = now
          @counter = 0
        else
          # Either we're still inside the same millisecond, or the wall clock
          # stepped backwards (NTP correction). Both cases keep issuing from the
          # last timestamp we used, so ids never go out of order.
          @counter += 1

          if @counter > MAX_COUNTER
            # 4096 ids in one millisecond. Borrow from the next millisecond
            # rather than wrapping the counter, which would break ordering.
            @last_ms += 1
            @counter = 0
          end
        end

        [ @last_ms, @counter ]
      end
    end

    def current_ms
      Process.clock_gettime(Process::CLOCK_REALTIME, :millisecond)
    end
  end
end
