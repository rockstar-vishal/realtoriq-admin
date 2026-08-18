# frozen_string_literal: true

module Admin
  class PlansController < BaseController
    before_action :set_plan, only: %i[edit update destroy]

    def index
      @plans = Plan.ordered
      @new_plan = Plan.new(interval: "month", max_devices: 3)
      @subscription_counts = Subscription.across_firms.live.group(:plan_id).count
    end

    def new
      @plan = Plan.new(interval: "month", max_devices: 3)
    end

    def create
      @plan = Plan.new(plan_params)

      if @plan.save
        redirect_to admin_plans_path, notice: "#{@plan.name} created."
      else
        @plans = Plan.ordered
        @subscription_counts = Subscription.across_firms.live.group(:plan_id).count
        @new_plan = @plan
        render :index, status: :unprocessable_content
      end
    end

    def edit; end

    def update
      if @plan.update(plan_params)
        redirect_to admin_plans_path, notice: "Changes saved."
      else
        render :edit, status: :unprocessable_content
      end
    end

    def destroy
      # restrict_with_error on the association: a plan a firm is on stays put,
      # otherwise their subscription would point at nothing.
      if @plan.destroy
        redirect_to admin_plans_path, notice: "#{@plan.name} deleted."
      else
        redirect_to admin_plans_path, alert: @plan.errors.full_messages.to_sentence
      end
    end

    private

    def set_plan
      @plan = Plan.find(params[:id])
    end

    def plan_params
      params.expect(plan: %i[name code price interval max_users max_devices active sort_order])
    end
  end
end
