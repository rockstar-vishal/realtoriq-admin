# frozen_string_literal: true

# MahaRERA Form 6 answers that are not already on the firm: the competency
# certificate, the signatory, the designated projects, and Table C. The shape
# is checked in Form6::Settings; unknown keys are dropped on write.
class AddForm6ToFirms < ActiveRecord::Migration[8.0]
  def change
    add_column :firms, :form6, :jsonb, null: false, default: {}
  end
end
