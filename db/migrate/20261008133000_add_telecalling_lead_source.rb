# frozen_string_literal: true

class AddTelecallingLeadSource < ActiveRecord::Migration[8.0]
  def up
    source_id = select_value("SELECT id FROM lead_sources WHERE lower(name) = 'telecalling'")
    if source_id.nil?
      sort_order = select_value("SELECT COALESCE(MAX(sort_order), -1) + 1 FROM lead_sources").to_i
      execute(<<~SQL.squish)
        INSERT INTO lead_sources (id, name, code, category, sort_order, active, created_at, updated_at)
        VALUES (gen_random_uuid(), 'Telecalling', 'telecalling', 'outbound', #{sort_order}, true, NOW(), NOW())
      SQL
      source_id = select_value("SELECT id FROM lead_sources WHERE code = 'telecalling'")
    end

    quoted = connection.quote(source_id)
    execute(<<~SQL.squish)
      UPDATE leads
      SET lead_source_id = #{quoted}, updated_at = NOW()
      WHERE lead_source_id IS NULL
        AND id IN (SELECT lead_id FROM prospects WHERE lead_id IS NOT NULL)
    SQL
  end

  def down
    source_id = select_value("SELECT id FROM lead_sources WHERE code = 'telecalling'")
    return if source_id.nil?

    quoted = connection.quote(source_id)
    execute(<<~SQL.squish)
      UPDATE leads
      SET lead_source_id = NULL, updated_at = NOW()
      WHERE lead_source_id = #{quoted}
        AND id IN (SELECT lead_id FROM prospects WHERE lead_id IS NOT NULL)
    SQL
    execute("DELETE FROM lead_sources WHERE id = #{quoted} AND NOT EXISTS (SELECT 1 FROM leads WHERE lead_source_id = #{quoted})")
  end
end
