# frozen_string_literal: true

module Admin
  # Skills & Trainings. Ops write the copy, upload the files, and publish.
  #
  # Files attach straight from this form rather than through the broker API's
  # ticket → PUT → attach flow. That flow exists to stop an untrusted client
  # minting upload tickets against our storage; an authenticated ops session is
  # not that, and putting a 40 MB podcast through a signed direct upload would
  # only add moving parts. The size and type caps live on the model instead.
  class TrainingsController < BaseController
    FILE_FIELDS = %i[banner document podcast].freeze

    before_action :set_training, only: %i[edit update activate archive destroy]

    def index
      @filter = params[:status].presence_in(Training::STATUSES + %w[all]) || "current"
      # The podcast attachment and the author are both read per row; without
      # these the list issues two queries per training.
      @trainings = filtered.newest_first.includes(:created_by_admin_user).with_attached_podcast
      @counts = Training.group(:status).count
    end

    def new
      @training = Training.new(language: "hinglish")
    end

    def create
      @training = Training.new(training_params)
      @training.created_by_admin_user = current_admin

      if @training.save
        redirect_to edit_admin_training_path(@training),
          notice: "Draft saved. Add the files, then activate it."
      else
        render :new, status: :unprocessable_content
      end
    end

    def edit; end

    def update
      if @training.update(training_params)
        redirect_to edit_admin_training_path(@training), notice: "Changes saved."
      else
        render :edit, status: :unprocessable_content
      end
    end

    def activate
      if @training.activate!(actor: current_admin)
        redirect_to admin_trainings_path, notice: "#{@training.title} is live."
      else
        redirect_to edit_admin_training_path(@training),
          alert: @training.errors.full_messages.to_sentence
      end
    end

    def archive
      @training.archive!(actor: current_admin)
      redirect_to admin_trainings_path,
        notice: "#{@training.title} archived. Brokers no longer see it."
    end

    def destroy
      unless @training.deletable?
        return redirect_to admin_trainings_path,
          alert: "#{@training.title} has been published, so it can only be archived."
      end

      title = @training.title
      # Recorded before the row goes: the audit row outlives its subject.
      AuditEvent.record!(subject: @training, actor: current_admin, action: "training.deleted",
                         metadata: { title: })
      @training.destroy!
      redirect_to admin_trainings_path, notice: "#{title} deleted."
    end

    private

    def set_training
      @training = Training.find(params[:id])
    end

    def filtered
      case @filter
      when "all" then Training.all
      when "current" then Training.where.not(status: "archived")
      else Training.where(status: @filter)
      end
    end

    def training_params
      permitted = params.expect(
        training: [ :title, :description, :intro_text, :instructions_text, :language,
                    :valid_upto, :podcast_url, :podcast_duration_seconds, *FILE_FIELDS ]
      )

      # An untouched file input posts an empty string. Left in, it would replace
      # the file already attached with nothing.
      FILE_FIELDS.each { |field| permitted.delete(field) if permitted[field].blank? }
      permitted
    end
  end
end
