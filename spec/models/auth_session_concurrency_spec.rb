# frozen_string_literal: true

require "rails_helper"

# Two concurrent refreshes used to both return 200 while only one digest was
# stored — the loser held a token that was already dead. Threads need a real
# commit to see each other's UPDATE, so transactional fixtures are off.
RSpec.describe "AuthSession refresh under concurrency" do
  self.use_transactional_tests = false

  let(:plan) { create(:plan, max_devices: 3) }
  let(:firm) { create(:firm, status: :active) }
  let(:subscription) { create(:subscription, firm:, plan:) }
  let(:user) { create(:user, :super_admin, firm:) }

  def truncate_everything
    conn = ActiveRecord::Base.connection
    tables = conn.tables - %w[schema_migrations ar_internal_metadata]
    conn.execute("TRUNCATE TABLE #{tables.map { |t| conn.quote_table_name(t) }.join(', ')} RESTART IDENTITY CASCADE")
  end

  before do
    truncate_everything
    Current.firm = firm
    subscription
    user
  end

  after do
    Current.firm = nil
    truncate_everything
  end

  def race(count)
    latch = Queue.new
    threads = Array.new(count) do
      Thread.new do
        latch.pop
        ActiveRecord::Base.connection_pool.with_connection do
          yield
        end
      end
    end
    count.times { latch << :go }
    threads.map(&:value)
  end

  it "lets exactly one of two concurrent rotations keep a live token" do
    session, token = AuthSession.start!(user:, device: { device_id: "phone-1" })
    digest = AuthSession.digest(token)

    results = race(2) do
      AuthSession.across_firms.find(session.id).rotate_if_matches!(digest)
    end

    expect(results.compact.size).to eq(1)
    expect(results.count(&:nil?)).to eq(1)
    expect(AuthSession.across_firms.find(session.id).refresh_token_digest)
      .to eq(AuthSession.digest(results.compact.sole))
  end
end
