# frozen_string_literal: true

require "pagy/extras/overflow"

# Admin tables show 25 rows; the broker API caps itself separately.
Pagy::DEFAULT[:limit] = 25
Pagy::DEFAULT[:overflow] = :last_page

Pagy::DEFAULT.freeze
