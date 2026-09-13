# frozen_string_literal: true

require "rails_helper"

RSpec.describe Inventory::ProjectSearch do
  let(:firm) { create(:firm) }

  before do
    Current.firm = firm
    create(:project, firm:, name: "Lodha Amara Tower 7")
  end

  after { Current.firm = nil }

  # The search applies two transaction-local settings with set_config. Issued
  # through select_value, an identical statement later in the same request or
  # job was answered from Rails' query cache and never reached Postgres — so a
  # second search silently ran with pg_trgm's default threshold, and "lodah",
  # which needs 0.45, stopped matching.
  it "applies its settings to a second search in the same request" do
    raw = ActiveRecord::Base.connection.raw_connection

    ActiveRecord::Base.cache do
      # An earlier, different search in the same request. It must differ, or the
      # second search's own queries come from the cache and hide the problem.
      described_class.new(query: "tower").call

      # In production that search's transaction ends and its SET LOCALs lapse.
      # Under transactional tests an outer transaction keeps them alive, which
      # would let a skipped set_config pass unnoticed — so lapse them by hand,
      # beneath Active Record, leaving the query cache exactly as it was.
      raw.exec("RESET pg_trgm.word_similarity_threshold")
      raw.exec("RESET enable_seqscan")

      result = described_class.new(query: "lodah").call

      expect(result.projects.map(&:name)).to eq([ "Lodha Amara Tower 7" ])
      expect(result.fuzzy).to be(true)
    end
  end
end
