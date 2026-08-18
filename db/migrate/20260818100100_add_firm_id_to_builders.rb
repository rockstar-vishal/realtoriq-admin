# frozen_string_literal: true

# Builders become firm-ownable alongside the platform's curated list.
#
# NULL firm_id means "everyone's" — the seeded developers ops maintain. A
# non-null one is a builder a broker added inline from the project form, visible
# only to their firm.
#
# This is why Builder is deliberately NOT FirmScoped: the fail-closed default
# scope would hide precisely the global rows every firm is supposed to see. The
# tenancy guard spec records the exemption.
class AddFirmIdToBuilders < ActiveRecord::Migration[8.0]
  def change
    add_reference :builders, :firm, foreign_key: true, type: :uuid, null: true

    # Was globally unique on name/slug. Now uniqueness has two halves, because
    # Postgres treats NULLs as distinct in a unique index — a plain
    # (firm_id, slug) index would let the global list hold "aurum-developers"
    # any number of times.
    remove_index :builders, :slug

    add_index :builders, :slug, unique: true,
      where: "firm_id IS NULL", name: "index_builders_on_slug_global"
    add_index :builders, :name, unique: true,
      where: "firm_id IS NULL", name: "index_builders_on_name_global"

    add_index :builders, [ :firm_id, :slug ], unique: true,
      where: "firm_id IS NOT NULL", name: "index_builders_on_firm_and_slug"
    add_index :builders, [ :firm_id, :name ], unique: true,
      where: "firm_id IS NOT NULL", name: "index_builders_on_firm_and_name"
  end
end
