# frozen_string_literal: true

require "rails_helper"
require "rake"

RSpec.describe "review demo tasks" do
  before(:all) do
    Rails.application.load_tasks unless Rake::Task.task_defined?("review_demo:setup")
  end

  def run_task(name)
    Rake::Task[name].tap(&:reenable).invoke
  end

  def masters
    city = create(:city, name: "Mumbai", state: "Maharashtra")
    create(:locality, city:, name: "Kharghar")
    create(:plan, name: "Growth")
    create(:builder, name: "Aurum Developers", firm: nil)
    create(:typology, name: "2 BHK")
    create(:property_type, name: "Ready possession")
    create(:lead_source, name: "Social / Meta")
    create(:lead_status, :new_lead)
  end

  it "setup twice leaves one firm, one user and one live subscription" do
    masters

    expect { run_task("review_demo:setup") }.to output(a_string_including("Review sign-in ready")).to_stdout
    expect { run_task("review_demo:setup") }.to output(a_string_including("Review sign-in ready")).to_stdout

    firm = Firm.find_by!(slug: "realtoriq-review-demo")
    expect(firm).to be_review_demo
    expect(firm.name).to eq("RealtorIQ Demo")
    expect(firm.pan).to be_nil
    expect(firm.rera_number).to be_nil
    expect(Firm.where(review_demo: true).count).to eq(1)
    expect(User.across_firms.where(mobile: "+919876754543").count).to eq(1)
    expect(firm.users.find_by(mobile: "+919876754543").name).to eq("Meta Reviewer")
    expect(firm.subscriptions.live.count).to eq(1)
    expect(firm.subscriptions.live.sole.current_period_end).to eq(Date.current + 12.months - 1.day)
    Current.set(firm:) do
      expect(firm.projects.count).to eq(2)
      expect(firm.leads.order(:name).pluck(:name)).to eq([
        "Sample Lead 1", "Sample Lead 2", "Sample Lead 3", "Sample Lead 4", "Sample Lead 5"
      ])
    end
  end

  it "does not print the sign-in code" do
    masters

    expect { run_task("review_demo:setup") }.to output(
      satisfy { |text| text.include?("Review sign-in ready") && text.exclude?(Auth::ReviewLogin::CODE) }
    ).to_stdout
  end

  it "aborts when the mobile already belongs to another firm" do
    other = create(:firm, status: :active)
    create(:user, :super_admin, firm: other, mobile: "+919876754543")

    expect { run_task("review_demo:setup") }.to raise_error(SystemExit)
      .and output(a_string_including(other.code)).to_stderr

    expect(Firm.where(review_demo: true)).to be_empty
    expect(User.across_firms.find_by(mobile: "+919876754543").firm_id).to eq(other.id)
  end

  it "rejects a second review demo firm" do
    create(:firm, review_demo: true)

    expect { create(:firm, review_demo: true) }.to raise_error(ActiveRecord::RecordNotUnique)
  end

  it "reset touches only the review demo firm" do
    masters
    run_task("review_demo:setup")
    firm = Firm.find_by!(slug: "realtoriq-review-demo")
    reviewer = firm.users.find_by!(mobile: "+919876754543")
    Current.firm = firm
    extra = create(:lead, firm:, name: "Temporary")
    connection = create(:facebook_connection, firm:, connected_by_user: reviewer)
    page = create(:facebook_page, firm:, facebook_connection: connection, page_access_token: "page-token",
      subscribed: true, status: "active")
    form = create(:facebook_lead_form, firm:, facebook_page: page)
    import = create(:facebook_lead_import, firm:, facebook_page: page, facebook_lead_form: form)
    Current.firm = nil

    other = create(:firm, status: :active)
    other_owner = create(:user, :super_admin, firm: other)
    other_lead = create(:lead, firm: other, name: "Keep me")
    other_connection = create(:facebook_connection, firm: other, connected_by_user: other_owner)
    other_page = create(:facebook_page, firm: other, facebook_connection: other_connection)
    client = instance_double(Facebook::GraphApiClient, unsubscribe_page: true)
    allow(Facebook::GraphApiClient).to receive(:new).and_return(client)

    run_task("review_demo:reset")

    expect(Lead.across_firms.find_by(id: extra.id)).to be_nil
    expect(FacebookPage.across_firms.find_by(id: page.id)).to be_nil
    expect(FacebookLeadForm.across_firms.find_by(id: form.id)).to be_nil
    expect(FacebookLeadImport.across_firms.find_by(id: import.id)).to be_nil
    expect(Lead.across_firms.where(firm_id: firm.id).pluck(:name)).to contain_exactly(
      "Sample Lead 1", "Sample Lead 2", "Sample Lead 3", "Sample Lead 4", "Sample Lead 5"
    )
    expect(Lead.across_firms.find_by(id: other_lead.id).name).to eq("Keep me")
    expect(FacebookPage.across_firms.find_by(id: other_page.id)).to be_present
    expect(client).to have_received(:unsubscribe_page).with(page.page_id)
  end

  it "refuses reset when no firm is flagged" do
    other = create(:firm, status: :active)
    lead = create(:lead, firm: other, name: "Keep me")

    expect { run_task("review_demo:reset") }.to raise_error(SystemExit)

    expect(Lead.across_firms.find_by(id: lead.id)).to be_present
  end
end
