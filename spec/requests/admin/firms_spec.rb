# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Admin firms" do
  before { sign_in_admin }

  let(:city) { create(:city, name: "Navi Mumbai", state: "Maharashtra", state_code: "MH") }
  let!(:plan) { create(:plan, name: "Growth", price: 2_499, interval: "month") }

  def valid_params(overrides = {})
    {
      firm: {
        name: "Sethi Realty",
        primary_contact_name: "Tanmay Sethi",
        contact_email: "ops@sethirealty.in",
        contact_mobile: "98201 44210",
        contact_whatsapp: "99300 71234",
        city_id: city.id,
        owner_name: "Tanmay Sethi",
        owner_email: "tanmay@sethirealty.in",
        owner_mobile: "9820144210",
        plan_id: plan.id,
        subscription_starts_on: Date.current.to_s,
        activate_immediately: "1"
      }.merge(overrides)
    }
  end

  describe "POST /admin/firms" do
    it "creates the firm" do
      expect { post admin_firms_path, params: valid_params }.to change(Firm, :count).by(1)

      expect(response).to redirect_to(admin_firm_path(Firm.last))
    end

    it "creates the super admin user in the same step" do
      # Regression: an earlier version derived "am I creating?" from
      # firm.persisted?, which flips to true the moment the firm saves — so the
      # owner was silently never created and the firm had no way to sign in.
      post admin_firms_path, params: valid_params

      firm = Firm.last
      owner = firm.users.sole

      expect(owner).to be_super_admin
      expect(owner.name).to eq("Tanmay Sethi")
      expect(owner.mobile).to eq("+919820144210")
      expect(owner).to be_active
    end

    it "creates all three contact channels, unverified" do
      post admin_firms_path, params: valid_params

      channels = Firm.last.contact_channels
      expect(channels.pluck(:kind)).to match_array(ContactChannel::KINDS)
      expect(channels.map(&:verification_state).uniq).to eq([ "unverified" ])
    end

    it "normalises the channel values it stores" do
      post admin_firms_path, params: valid_params

      channels = Firm.last.contact_channels.index_by(&:kind)
      expect(channels["mobile"].value).to eq("+919820144210")
      expect(channels["whatsapp"].value).to eq("+919930071234")
      expect(channels["email"].value).to eq("ops@sethirealty.in")
    end

    it "mirrors the mobile into WhatsApp when asked to" do
      post admin_firms_path, params: valid_params(
        contact_whatsapp: "", whatsapp_same_as_mobile: "1"
      )

      channels = Firm.last.contact_channels.index_by(&:kind)
      expect(channels["whatsapp"].value).to eq(channels["mobile"].value)
    end

    it "derives the code from the city's state code" do
      post admin_firms_path, params: valid_params

      expect(Firm.last.code).to match(/\ACP-MH-\d{5}\z/)
    end

    it "records an audit event" do
      post admin_firms_path, params: valid_params

      expect(AuditEvent.where(action: "firm.created").count).to eq(1)
    end

    describe "the firm it produces is immediately usable" do
      # The whole reason the subscription and activation moved onto this form:
      # before, creating a firm left it pending with no plan, and its broker got
      # subscription_lapsed on first sign-in.
      it "gives the firm a live subscription" do
        post admin_firms_path, params: valid_params

        subscription = Firm.last.current_subscription
        expect(subscription.plan).to eq(plan)
        expect(subscription).to be_entitled
        expect(subscription.amount).to eq(2_499)
      end

      it "ends the period according to the plan's interval" do
        post admin_firms_path, params: valid_params

        subscription = Firm.last.current_subscription
        expect(subscription.current_period_end).to eq(Date.current + 1.month - 1.day)
      end

      it "activates the firm when asked" do
        post admin_firms_path, params: valid_params

        expect(Firm.last).to be_active
        expect(Firm.last.activated_at).to be_present
      end

      it "leaves it pending when not asked" do
        post admin_firms_path, params: valid_params(activate_immediately: "0")

        expect(Firm.last).to be_pending
        expect(Firm.last.current_subscription).to be_present
      end

      it "honours a future start date" do
        post admin_firms_path, params: valid_params(subscription_starts_on: 1.week.from_now.to_date.to_s)

        expect(Firm.last.current_subscription.current_period_start).to eq(1.week.from_now.to_date)
      end

      it "records which admin set the subscription up" do
        post admin_firms_path, params: valid_params

        expect(Firm.last.current_subscription.created_by_admin).to be_an(AdminUser)
      end
    end

    context "when the input is bad" do
      it "requires a plan while any active plan exists" do
        post admin_firms_path, params: valid_params(plan_id: "")

        expect(response).to have_http_status(:unprocessable_content)
        expect(Firm.count).to eq(0)
      end

      it "still creates a firm when no plans have been defined yet" do
        # A brand-new installation should not be blocked from onboarding its
        # first firm just because nobody has priced anything.
        plan.update!(active: false)

        post admin_firms_path, params: valid_params(plan_id: "")

        expect(response).to redirect_to(admin_firm_path(Firm.last))
        expect(Firm.last.current_subscription).to be_nil
      end

      it "rolls the subscription back with everything else when the owner is invalid" do
        expect {
          post admin_firms_path, params: valid_params(owner_mobile: "nonsense")
        }.not_to change(Subscription, :count)

        expect(Firm.count).to eq(0)
      end
    end

    context "when the input is bad" do
      it "rejects a missing name and re-renders" do
        post admin_firms_path, params: valid_params(name: "")

        expect(response).to have_http_status(:unprocessable_content)
        expect(Firm.count).to eq(0)
      end

      it "rejects a duplicate owner mobile, since it must be globally unique" do
        create(:user, mobile: "+919820144210")

        expect { post admin_firms_path, params: valid_params }.not_to change(Firm, :count)

        # Surfaced against the owner field the admin typed into, not as a
        # generic base error.
        expect(response.body).to include("Owner mobile has already been taken")
        expect(response.body).to include('name="firm[owner_mobile]"')
      end

      it "rolls the firm back entirely when the owner is invalid" do
        # The whole point of the transaction: no orphan firm with no way in.
        post admin_firms_path, params: valid_params(owner_mobile: "nonsense")

        expect(Firm.count).to eq(0)
        expect(ContactChannel.across_firms.count).to eq(0)
      end

      it "requires an owner mobile when creating" do
        post admin_firms_path, params: valid_params(owner_mobile: "")

        expect(response).to have_http_status(:unprocessable_content)
        expect(Firm.count).to eq(0)
      end
    end
  end

  describe "PATCH /admin/firms/:slug" do
    let!(:firm) { create(:firm, :with_channels, name: "Sethi Realty") }

    it "saves changes without touching the owner fields" do
      patch admin_firm_path(firm), params: { firm: {
        name: "Sethi Realty LLP",
        contact_email: firm.contact_channels.find_by(kind: :email).value,
        contact_mobile: firm.contact_channels.find_by(kind: :mobile).value
      } }

      expect(firm.reload.name).to eq("Sethi Realty LLP")
    end

    it "clears verification when a channel's value actually changes" do
      email = firm.contact_channels.find_by(kind: :email)
      email.mark_verified!

      patch admin_firm_path(firm), params: { firm: {
        name: firm.name,
        contact_email: "new-ops@sethirealty.in",
        contact_mobile: firm.contact_channels.find_by(kind: :mobile).value
      } }

      expect(email.reload).not_to be_verified
    end

    it "keeps verification when the same number is retyped in another format" do
      # Normalisation happens before the comparison, so "98201 44210" and
      # "+919820144210" are recognised as the same number and the badge stands.
      mobile = firm.contact_channels.find_by(kind: :mobile)
      mobile.update!(value: "+919820144210")
      mobile.mark_verified!

      patch admin_firm_path(firm), params: { firm: {
        name: firm.name,
        contact_email: firm.contact_channels.find_by(kind: :email).value,
        contact_mobile: "098201 44210"
      } }

      expect(mobile.reload).to be_verified
    end
  end

  describe "suspending and activating" do
    let!(:firm) { create(:firm) }

    it "requires a reason to suspend" do
      patch suspend_admin_firm_path(firm), params: { firm: { suspension_reason: "  " } }

      expect(firm.reload).not_to be_suspended
      expect(flash[:alert]).to eq("A suspension needs a reason.")
    end

    it "suspends with a reason and records who did it" do
      patch suspend_admin_firm_path(firm), params: { firm: { suspension_reason: "Payment overdue" } }

      expect(firm.reload).to be_suspended
      expect(firm.suspension_reason).to eq("Payment overdue")
      expect(AuditEvent.find_by(action: "firm.suspended").actor).to be_an(AdminUser)
    end

    it "reactivates a suspended firm" do
      firm.suspend!(reason: "Payment overdue")

      patch activate_admin_firm_path(firm)

      expect(firm.reload).to be_active
      expect(firm.suspension_reason).to be_nil
    end
  end

  describe "GET /admin/firms" do
    it "lists firms across every tenant" do
      create_list(:firm, 3)

      get admin_firms_path

      expect(response.body).to include("3 firms")
    end

    it "filters by status" do
      create(:firm, name: "Active Co")
      create(:firm, :suspended, name: "Suspended Co")

      get admin_firms_path(status: "suspended")

      expect(response.body).to include("Suspended Co")
      expect(response.body).not_to include("Active Co")
    end

    it "finds a firm by a user's mobile number" do
      firm = create(:firm, name: "Findable Realty")
      create(:user, firm:, mobile: "+919820144210")
      create(:firm, name: "Other Realty")

      get admin_firms_path(q: "9820144210")

      expect(response.body).to include("Findable Realty")
      expect(response.body).not_to include("Other Realty")
    end

    it "filters to firms with an unverified channel" do
      complete = create(:firm, :with_channels, name: "Complete Realty")
      complete.contact_channels.each(&:mark_verified!)
      create(:firm, :with_channels, name: "Partial Realty")

      get admin_firms_path(verification: "incomplete")

      expect(response.body).to include("Partial Realty")
      expect(response.body).not_to include("Complete Realty")
    end
  end
end
