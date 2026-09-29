# frozen_string_literal: true

# Skills & Trainings. A training is platform content, not tenant data: KGen ops
# publish one and every firm sees it, so there is no firm_id here and no
# FirmScoped. The broker's own notes against it are tenant data, and are.
class CreateTrainings < ActiveRecord::Migration[8.0]
  def change
    create_table :trainings, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.string :title, null: false
      t.text :description, null: false
      # Plain text by decision: the detail screen renders paragraphs, not markup.
      t.text :intro_text, null: false
      # Blank means "use the app's default steps".
      t.text :instructions_text
      t.string :language, null: false, default: "hinglish"
      t.string :status, null: false, default: "draft"
      # Null means it never expires. The broker list hides anything past it.
      t.date :valid_upto
      # Either an uploaded file (Active Storage) or a link ops paste in. The
      # generator will fill this column when it is wired.
      t.string :podcast_url
      t.integer :podcast_duration_seconds
      t.references :created_by_admin_user, type: :uuid, null: true,
        foreign_key: { to_table: :admin_users, on_delete: :nullify }
      # Set on first activation. Drives "newest first", so editing a live
      # training does not jump it above the others.
      t.datetime :published_at
      t.timestamps
    end

    add_index :trainings, [ :status, :published_at ], order: { published_at: :desc }
    add_index :trainings, :language

    add_check_constraint :trainings,
      "language IN ('hinglish', 'en', 'mr')", name: "trainings_language_check"
    # 'generating' joins this list when podcast generation is wired; an
    # unreachable state today would only invite a row that means nothing.
    add_check_constraint :trainings,
      "status IN ('draft', 'active', 'archived')", name: "trainings_status_check"
    add_check_constraint :trainings,
      "podcast_duration_seconds IS NULL OR podcast_duration_seconds > 0",
      name: "trainings_podcast_duration_check"

    create_table :training_notes, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.references :firm, type: :uuid, null: false, foreign_key: true
      t.references :user, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.references :training, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.text :body, null: false
      t.timestamps
    end

    # One running note per broker per training.
    add_index :training_notes, [ :user_id, :training_id ], unique: true
  end
end
