# frozen_string_literal: true

# Typo-tolerant project search (GET /api/v1/projects/search).
#
# pg_trgm splits text into three-character sequences, which is what lets "aurm"
# still find "Aurum Vista". The GIN indexes are what keep that fast as the pool
# grows: both the substring match (ILIKE) and the fuzzy match (<%) are
# answered from the index rather than by reading every row.
#
# Deliberately a normal, transactional migration — not CREATE INDEX
# CONCURRENTLY. Concurrent builds each commit on their own, so one cancelled
# partway (a lock wait, a timeout, a deploy killing the process) leaves an
# INVALID index behind and the migration unrecorded; re-running it then fails
# on "relation already exists" until someone drops the leftover by hand. Here
# either everything lands or nothing does, and a failed run can simply be run
# again. The trade is a brief write lock on `projects` while the indexes build,
# which is negligible at the size the table is today. A future index on a large
# `projects` should use CONCURRENTLY with a guard that drops an invalid leftover.
#
# Deploy note: CREATE EXTENSION needs the database role to be allowed to create
# it. pg_trgm is a *trusted* extension from PostgreSQL 13, so the owner of the
# database can create it without superuser — which covers a role made with
# `createuser --createdb` that then created the database, as on staging. On
# Ubuntu it ships in the postgresql-contrib modules; on a managed Postgres (RDS
# and the like) it is on the allowed list.
class AddTrigramSearchToProjects < ActiveRecord::Migration[8.0]
  def change
    enable_extension "pg_trgm"

    add_index :projects, :name,
      using: :gin, opclass: :gin_trgm_ops, name: "index_projects_on_name_trgm"

    add_index :projects, :rera_number,
      using: :gin, opclass: :gin_trgm_ops, name: "index_projects_on_rera_number_trgm"
  end
end
