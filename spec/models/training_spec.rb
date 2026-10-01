# frozen_string_literal: true

require "rails_helper"

RSpec.describe Training do
  def attach(training, name, bytes: 100, content_type: "image/png", filename: "file.png")
    training.public_send(name).attach(
      io: StringIO.new("x" * bytes), filename:, content_type:
    )
    training
  end

  describe "validity" do
    it "needs the copy a broker reads" do
      training = build(:training, title: nil, description: nil, intro_text: nil)

      expect(training).not_to be_valid
      expect(training.errors.attribute_names).to include(:title, :description, :intro_text)
    end

    it "refuses a language outside the list" do
      expect(build(:training, language: "tamil")).not_to be_valid
    end

    it "refuses a podcast link that isn't https" do
      expect(build(:training, podcast_url: "http://example.com/a.mp3")).not_to be_valid
    end

    it "refuses a banner over 2 MB" do
      training = attach(build(:training), :banner, bytes: 3.megabytes)

      expect(training).not_to be_valid
      expect(training.errors[:banner].first).to include("2 MB")
    end

    it "refuses a guide that isn't a PDF" do
      training = attach(build(:training), :document,
                        content_type: "application/msword", filename: "guide.doc")

      expect(training).not_to be_valid
      expect(training.errors[:document].first).to include("application/pdf")
    end
  end

  describe "activation" do
    it "lists everything still missing" do
      training = create(:training)

      expect(training.activation_blockers)
        .to contain_exactly("a banner image", "the PDF guide")
    end

    it "refuses while anything is missing, and says so" do
      training = create(:training)

      expect(training.activate!(actor: create(:admin_user))).to be(false)
      expect(training.reload).to be_draft
      expect(training.errors.full_messages.first).to include("Still needs")
    end

    it "goes live without any podcast, because the guide is the training" do
      training = create(:training, :with_assets)
      training.podcast.purge

      expect(training.activation_blockers).to be_empty
      expect(training.activate!(actor: create(:admin_user))).to be(true)
    end

    it "refuses when the valid-upto date has already passed" do
      training = create(:training, :with_assets, valid_upto: 1.day.ago.to_date)

      expect(training.activate!).to be(false)
      expect(training.activation_blockers).to include("a valid-upto date that has not passed")
    end

    it "goes live, stamps published_at and records who did it" do
      admin = create(:admin_user)
      training = create(:training, :with_assets)

      expect(training.activate!(actor: admin)).to be(true)
      expect(training.reload).to be_active
      expect(training.published_at).to be_present
      expect(AuditEvent.last.action).to eq("training.activated")
      expect(AuditEvent.last.actor).to eq(admin)
    end

    it "announces the first publication, once" do
      training = create(:training, :with_assets)

      expect { training.activate! }
        .to have_enqueued_job(Trainings::AnnounceJob).with(training.id)
    end

    it "keeps quiet when an archived training is activated again" do
      training = create(:training, :archived)

      expect { training.activate! }.not_to have_enqueued_job(Trainings::AnnounceJob)
    end

    it "keeps the original published_at when a training is activated again" do
      training = create(:training, :archived)
      first_published = training.published_at

      training.activate!

      expect(training.reload.published_at).to be_within(1.second).of(first_published)
      expect(AuditEvent.last.metadata["first_publication"]).to be(false)
    end

    it "archives with an audit row" do
      training = create(:training, :active)

      training.archive!(actor: create(:admin_user))

      expect(training.reload).to be_archived
      expect(AuditEvent.last.action).to eq("training.archived")
    end
  end

  describe ".live" do
    it "shows an active training with no expiry" do
      training = create(:training, :active, valid_upto: nil)

      expect(described_class.live).to include(training)
    end

    it "still shows one on its last valid day" do
      training = create(:training, :active, valid_upto: Date.current)

      expect(described_class.live).to include(training)
    end

    it "hides one whose date has passed" do
      training = create(:training, :active, valid_upto: 1.day.ago.to_date)

      expect(described_class.live).not_to include(training)
    end

    it "hides drafts and archived trainings" do
      draft = create(:training)
      archived = create(:training, :archived)

      expect(described_class.live).not_to include(draft, archived)
    end
  end

  describe ".newest_first" do
    it "orders by publication, and a draft by when it was written" do
      older = create(:training, :active, published_at: 3.days.ago)
      newer = create(:training, :active, published_at: 1.hour.ago)
      draft = create(:training)

      expect(described_class.newest_first.to_a).to eq([ draft, newer, older ])
    end
  end

  describe "#deletable?" do
    it "allows a draft that was never published" do
      expect(create(:training)).to be_deletable
    end

    it "refuses one that has been live" do
      expect(create(:training, :archived)).not_to be_deletable
    end
  end
end
