# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Admin trainings" do
  let(:admin) { create(:admin_user, name: "Priya Ops") }

  before { sign_in_admin(admin) }

  def upload(fixture, content_type)
    Rack::Test::UploadedFile.new(StringIO.new("x" * 200), content_type, original_filename: fixture)
  end

  describe "index" do
    it "lists current trainings and hides archived ones by default" do
      create(:training, :active, title: "Closing Techniques")
      create(:training, :archived, title: "Old Course")

      get admin_trainings_path

      expect(response.body).to include("Closing Techniques")
      expect(response.body).not_to include("Old Course")
    end

    it "shows archived ones when asked" do
      create(:training, :archived, title: "Old Course")

      get admin_trainings_path(status: "archived")

      expect(response.body).to include("Old Course")
    end
  end

  describe "create" do
    it "saves a draft and records who wrote it" do
      post admin_trainings_path, params: {
        training: {
          title: "Digital Marketing Simplified",
          description: "Leads from your phone, compliantly.",
          intro_text: "Aapne portal ko paisa diya. Kitne bookings hue?",
          language: "hinglish"
        }
      }

      training = Training.find_by(title: "Digital Marketing Simplified")
      expect(training).to be_draft
      expect(training.created_by_admin_user).to eq(admin)
      expect(response).to redirect_to(edit_admin_training_path(training))
    end

    it "re-renders with the errors when the copy is missing" do
      post admin_trainings_path, params: { training: { title: "", description: "", intro_text: "" } }

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include("stopped this from saving")
    end
  end

  describe "update" do
    it "attaches the files ops upload" do
      training = create(:training)

      patch admin_training_path(training), params: {
        training: {
          banner: upload("banner.png", "image/png"),
          document: upload("guide.pdf", "application/pdf"),
          podcast: upload("episode.mp3", "audio/mpeg"),
          podcast_duration_seconds: 1200
        }
      }

      training.reload
      expect(training.banner).to be_attached
      expect(training.document.filename.to_s).to eq("guide.pdf")
      expect(training.podcast_duration_seconds).to eq(1200)
    end

    it "keeps the file already attached when the file input is left empty" do
      training = create(:training, :with_assets)
      original = training.document.blob.id

      patch admin_training_path(training),
        params: { training: { title: "Renamed", banner: "", document: "", podcast: "" } }

      training.reload
      expect(training.title).to eq("Renamed")
      expect(training.document.blob.id).to eq(original)
    end
  end

  describe "activate" do
    it "refuses while files are missing and says what's needed" do
      training = create(:training)

      patch activate_admin_training_path(training)

      expect(training.reload).to be_draft
      expect(flash[:alert]).to include("Still needs")
    end

    it "publishes a complete training" do
      training = create(:training, :with_assets)

      patch activate_admin_training_path(training)

      expect(training.reload).to be_active
      expect(training.published_at).to be_present
    end
  end

  describe "archive" do
    it "takes a live training away from brokers" do
      training = create(:training, :active)

      patch archive_admin_training_path(training)

      expect(training.reload).to be_archived
    end
  end

  describe "destroy" do
    it "deletes a draft that was never published" do
      training = create(:training)

      delete admin_training_path(training)

      expect(Training.exists?(training.id)).to be(false)
      expect(AuditEvent.last.action).to eq("training.deleted")
    end

    it "refuses to delete anything that has been published" do
      training = create(:training, :archived)

      delete admin_training_path(training)

      expect(Training.exists?(training.id)).to be(true)
      expect(flash[:alert]).to include("archived")
    end
  end

  it "keeps the whole section behind an admin session" do
    delete admin_session_path

    get admin_trainings_path

    expect(response).to redirect_to(new_admin_session_path)
  end
end
