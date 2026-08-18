# frozen_string_literal: true

require "rails_helper"
require "rake"

# Seed and bootstrap tasks are the first thing anyone runs on a new checkout and
# the last thing anyone thinks to test. They break quietly — a renamed column or
# a new NOT NULL surfaces months later as "setup doesn't work".
RSpec.describe "Bootstrap tasks", :silence_output do
  before(:all) do
    Rails.application.load_tasks unless Rake::Task.task_defined?("admin:create")
  end

  def run_task(name)
    Rake::Task[name].tap(&:reenable).invoke
  end

  around do |example|
    original = ENV.to_hash
    example.run
    ENV.replace(original)
  end

  describe "db:seed" do
    it "creates the reference data the broker app depends on" do
      load Rails.root.join("db/seeds.rb")

      expect(City.count).to be_positive
      expect(Locality.count).to be_positive
      expect(Typology.count).to be_positive
      expect(LeadSource.count).to be_positive
      expect(PropertyType.count).to be_positive
      expect(Plan.active.count).to be_positive
    end

    it "seeds the lead statuses with the flags the reports depend on" do
      load Rails.root.join("db/seeds.rb")

      expect(LeadStatus.find_by(name: "Dead")).to be_is_dead
      expect(LeadStatus.find_by(name: "Booked")).to be_is_booked
    end

    it "is idempotent" do
      load Rails.root.join("db/seeds.rb")
      counts = [ City.count, Locality.count, Plan.count, LeadStatus.count ]

      load Rails.root.join("db/seeds.rb")

      expect([ City.count, Locality.count, Plan.count, LeadStatus.count ]).to eq(counts)
    end

    it "creates no admin user — there must be no known credential to inherit" do
      load Rails.root.join("db/seeds.rb")

      expect(AdminUser.count).to eq(0)
    end

    it "creates no firms" do
      load Rails.root.join("db/seeds.rb")

      expect(Firm.count).to eq(0)
    end
  end

  describe "admin:create" do
    it "creates an admin who can sign in" do
      ENV["ADMIN_EMAIL"] = "ops@realtoriq.in"
      ENV["ADMIN_PASSWORD"] = "a-long-enough-password"

      expect { run_task("admin:create") }.to change(AdminUser, :count).by(1)

      admin = AdminUser.find_by(email: "ops@realtoriq.in")
      expect(admin.authenticate("a-long-enough-password")).to be_truthy
      expect(admin).to be_active
    end

    it "derives a name from the email when none is given" do
      ENV["ADMIN_EMAIL"] = "jane.doe@realtoriq.in"
      ENV["ADMIN_PASSWORD"] = "a-long-enough-password"

      run_task("admin:create")

      expect(AdminUser.find_by(email: "jane.doe@realtoriq.in").name).to eq("Jane Doe")
    end

    it "updates the password of an existing admin rather than duplicating them" do
      admin = create(:admin_user, email: "ops@realtoriq.in")
      ENV["ADMIN_EMAIL"] = "ops@realtoriq.in"
      ENV["ADMIN_PASSWORD"] = "a-different-password"

      expect { run_task("admin:create") }.not_to change(AdminUser, :count)
      expect(admin.reload.authenticate("a-different-password")).to be_truthy
    end

    it "reactivates a deactivated admin" do
      create(:admin_user, :deactivated, email: "ops@realtoriq.in")
      ENV["ADMIN_EMAIL"] = "ops@realtoriq.in"
      ENV["ADMIN_PASSWORD"] = "a-long-enough-password"

      run_task("admin:create")

      expect(AdminUser.find_by(email: "ops@realtoriq.in")).to be_active
    end

    it "refuses a password the model considers too short" do
      ENV["ADMIN_EMAIL"] = "ops@realtoriq.in"
      ENV["ADMIN_PASSWORD"] = "short"

      expect { run_task("admin:create") }.to raise_error(SystemExit)
      expect(AdminUser.count).to eq(0)
    end

    it "refuses to run without an email" do
      ENV.delete("ADMIN_EMAIL")

      expect { run_task("admin:create") }.to raise_error(SystemExit)
    end
  end

  describe "admin:deactivate" do
    it "deactivates the admin and ends their open sessions" do
      admin = create(:admin_user, email: "ops@realtoriq.in")
      admin.admin_sessions.create!(last_seen_at: Time.current)
      ENV["ADMIN_EMAIL"] = "ops@realtoriq.in"

      run_task("admin:deactivate")

      expect(admin.reload).not_to be_active
      expect(admin.admin_sessions.count).to eq(0)
    end
  end

  describe "demo:seed" do
    before { load Rails.root.join("db/seeds.rb") }

    it "creates a firm that can actually sign in" do
      run_task("demo:seed")

      Current.firm_scope_bypassed = true
      firm = Firm.find_by(slug: "sethi-realty")

      expect(firm).to be_active
      expect(firm.current_subscription).to be_entitled
      expect(firm.users.count).to eq(3)
    end

    it "leaves WhatsApp unverified, so the verification flow is demonstrable" do
      run_task("demo:seed")

      Current.firm_scope_bypassed = true
      channels = Firm.find_by(slug: "sethi-realty").contact_channels.index_by(&:kind)

      expect(channels["email"]).to be_verified
      expect(channels["mobile"]).to be_verified
      expect(channels["whatsapp"]).not_to be_verified
    end

    it "resets the demo state on every run rather than drifting" do
      run_task("demo:seed")
      Current.firm_scope_bypassed = true
      Firm.find_by(slug: "sethi-realty").contact_channels.find_by(kind: :whatsapp).mark_verified!

      run_task("demo:seed")

      expect(Firm.find_by(slug: "sethi-realty").contact_channels.find_by(kind: :whatsapp))
        .not_to be_verified
    end

    it "creates one user of each role, so permissions are visible without editing" do
      run_task("demo:seed")

      Current.firm_scope_bypassed = true
      expect(Firm.find_by(slug: "sethi-realty").users.pluck(:role))
        .to match_array(%w[super_admin manager agent])
    end

    it "is idempotent" do
      run_task("demo:seed")
      run_task("demo:seed")

      Current.firm_scope_bypassed = true
      expect(Firm.where(slug: "sethi-realty").count).to eq(1)
      expect(Firm.find_by(slug: "sethi-realty").subscriptions.live.count).to eq(1)
    end

    it "refuses to run in production" do
      allow(Rails).to receive(:env).and_return(ActiveSupport::StringInquirer.new("production"))

      expect { run_task("demo:seed") }.to raise_error(SystemExit)
    end
  end

  describe "demo:clear" do
    it "removes the demo firm and everything under it" do
      load Rails.root.join("db/seeds.rb")
      run_task("demo:seed")

      run_task("demo:clear")

      Current.firm_scope_bypassed = true
      expect(Firm.find_by(slug: "sethi-realty")).to be_nil
      expect(User.across_firms.count).to eq(0)
    end
  end
end
