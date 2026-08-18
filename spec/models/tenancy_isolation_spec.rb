# frozen_string_literal: true

require "rails_helper"

# The load-bearing spec of the whole multitenancy design.
#
# Row-level tenancy only holds if every firm-owned model is actually scoped. A
# reviewer can miss that on a new model; this can't.
RSpec.describe "Tenancy isolation" do
  # Tables that carry firm_id but are NOT tenant data in the FirmScoped sense.
  # Adding to this list should be a conscious argument, not a convenience.
  EXEMPT_FROM_FIRM_SCOPING = %w[
    audit_events
    builders
  ].freeze

  # Why builders are exempt, asserted rather than left as a comment: the table
  # holds both the platform's curated list (firm_id NULL) and firm-added ones.
  # A fail-closed tenant scope would resolve to `firm_id IS NULL` and hide every
  # firm-owned builder — and any attempt to "fix" that by scoping to the firm
  # would hide the global list from everyone.
  describe "Builder's deliberate exemption" do
    let(:firm) { create(:firm) }

    it "shows a firm the global list plus its own, and nobody else's" do
      global = create(:builder, firm: nil, name: "Platform Developers")
      mine = create(:builder, firm:, name: "My Developers")
      create(:builder, firm: create(:firm), name: "Someone Else's")

      expect(Builder.available_to(firm).pluck(:id)).to contain_exactly(global.id, mine.id)
    end

    it "shows only the global list when there is no firm" do
      global = create(:builder, firm: nil)
      create(:builder, firm:)

      expect(Builder.available_to(nil).pluck(:id)).to eq([ global.id ])
    end
  end

  def application_models
    Rails.application.eager_load!

    ApplicationRecord.descendants.reject do |model|
      model.abstract_class? || !model.table_exists?
    end
  end

  describe "every model with a firm_id column" do
    it "includes FirmScoped" do
      offenders = application_models.select do |model|
        model.column_names.include?("firm_id") &&
          !model.table_name.in?(EXEMPT_FROM_FIRM_SCOPING) &&
          !model.include?(FirmScoped)
      end

      expect(offenders).to be_empty,
        "These models have a firm_id but aren't FirmScoped, so their queries " \
        "cross tenant boundaries: #{offenders.map(&:name).join(', ')}. " \
        "Include FirmScoped, or add the table to EXEMPT_FROM_FIRM_SCOPING with a reason."
    end
  end

  describe "every FirmScoped model" do
    let(:firm_a) { create(:firm) }
    let(:firm_b) { create(:firm) }

    it "is fail-closed when no firm is set" do
      # The dangerous default would be "return everything". A request that
      # forgets to establish a tenant must see nothing instead.
      create(:user, firm: firm_a)
      Current.firm = nil

      expect(User.count).to eq(0)
      expect(ContactChannel.count).to eq(0)
    end

    it "returns only the current firm's rows" do
      a_user = create(:user, firm: firm_a)
      create(:user, firm: firm_b)

      Current.firm = firm_a

      expect(User.pluck(:id)).to eq([ a_user.id ])
    end

    it "does not leak another firm's row through find" do
      b_user = create(:user, firm: firm_b)

      Current.firm = firm_a

      expect { User.find(b_user.id) }.to raise_error(ActiveRecord::RecordNotFound)
    end

    it "stamps firm_id from Current on create" do
      Current.firm = firm_a

      user = User.create!(name: "Tanmay Sethi", mobile: "9820144210")

      expect(user.firm_id).to eq(firm_a.id)
    end

    it "exposes cross-firm reads only through an explicit call" do
      create(:user, firm: firm_a)
      create(:user, firm: firm_b)

      Current.firm = firm_a

      expect(User.count).to eq(1)
      expect(User.across_firms.count).to eq(2)
    end
  end

  describe "the admin panel's scope bypass" do
    let(:firm_a) { create(:firm) }
    let(:firm_b) { create(:firm) }

    it "is off unless something deliberately turns it on" do
      expect(Current.firm_scope_bypassed).to be_falsey
    end

    it "reads across every firm when on" do
      create(:user, firm: firm_a)
      create(:user, firm: firm_b)

      Current.firm_scope_bypassed = true

      expect(User.count).to eq(2)
    end

    it "is not needed for a firm's direct associations" do
      # Rails replaces the default scope's firm_id condition with the
      # association's own foreign key, so this is safe with the bypass off.
      # Pinned down because it is the opposite of what you'd expect.
      create(:user, firm: firm_a)

      expect(firm_a.users.count).to eq(1)
    end

    it "closes the join trap it exists for" do
      # A join is the case that actually breaks: the default scope lands in the
      # WHERE clause next to the join, so `users.firm_id IS NULL` eliminates
      # every row and the query quietly returns nothing.
      create(:user, firm: firm_a)

      expect(Firm.left_joins(:users).where.not(users: { id: nil }).count).to eq(0)

      Current.firm_scope_bypassed = true
      expect(Firm.left_joins(:users).where.not(users: { id: nil }).count).to eq(1)
    end

    it "is cleared by Current.reset, so it cannot outlive a request" do
      Current.firm_scope_bypassed = true
      Current.reset

      expect(Current.firm_scope_bypassed).to be_falsey
    end
  end

  # How the fail-closed default scope interacts with associations is not
  # uniform, and getting it wrong produces silent empty results rather than
  # errors. All three cases are pinned here because every one of them caused a
  # real bug during this build.
  describe "associations into firm-scoped models" do
    let(:firm) { create(:firm) }

    it "resolves when the association's own key IS firm_id" do
      # Rails replaces the default scope's firm_id condition with the
      # association's foreign key, so this works with no tenant set.
      create(:user, firm:)

      expect(firm.users.count).to eq(1)
    end

    it "needs unscoping when the association's key is something else" do
      # user.auth_sessions is keyed on user_id, so `firm_id IS NULL` survives
      # from the default scope. AuthSession is created during sign-in, before a
      # tenant exists, so the association is declared unscoped.
      user = create(:user, firm:)
      AuthSession.start!(user:)

      expect(user.auth_sessions.live.count).to eq(1)
    end

    it "needs unscoping on a belongs_to into a scoped model" do
      # A belongs_to gets no foreign-key substitution at all, so a scoped target
      # resolves to nil. OneTimeCode#user is looked up to authenticate someone —
      # if this returned nil, nobody could ever sign in.
      user = create(:user, firm:)
      code, = OneTimeCode.issue!(purpose: "login", destination: user.mobile, user:)

      expect(code.reload.user).to eq(user)
    end
  end

  describe "Firm itself" do
    it "is not FirmScoped — it is the scope" do
      expect(Firm.include?(FirmScoped)).to be(false)
    end
  end
end
