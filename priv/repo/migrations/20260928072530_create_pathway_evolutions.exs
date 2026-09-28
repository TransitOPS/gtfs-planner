defmodule GtfsPlanner.Repo.Migrations.CreatePathwayEvolutions do
  use Ecto.Migration

  @identity_check "pathway_evolutions_identity_check"
  @window_check "pathway_evolutions_window_check"
  @closure_index "pathway_evolutions_closure_index"
  @service_index "pathway_evolutions_service_id_index"
  @pathway_fkey "pathway_evolutions_pathway_fkey"

  def up do
    create table(:pathway_evolutions, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :pathway_id, :string, null: false
      add :service_id, :string, null: false
      add :start_time, :integer, null: false
      add :end_time, :integer, null: false
      add :note, :string

      add :organization_id, references(:organizations, type: :binary_id, on_delete: :delete_all),
        null: false

      # No gtfs_versions foreign key: the other GTFS tables dropped theirs in
      # 20260125014906_remove_gtfs_foreign_key_constraints.exs. Version scope is
      # enforced by the composite pathway reference below.
      add :gtfs_version_id, :binary_id, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create constraint(:pathway_evolutions, @identity_check,
             check: "btrim(pathway_id) <> '' AND btrim(service_id) <> ''"
           )

    create constraint(:pathway_evolutions, @window_check,
             check: "start_time >= 0 AND end_time > start_time AND end_time <= 2147483647"
           )

    create unique_index(
             :pathway_evolutions,
             [
               :organization_id,
               :gtfs_version_id,
               :pathway_id,
               :service_id,
               :start_time,
               :end_time
             ],
             name: @closure_index
           )

    create index(:pathway_evolutions, [:organization_id, :gtfs_version_id, :service_id],
             name: @service_index
           )

    execute("""
    ALTER TABLE #{qualified_table(:pathway_evolutions)}
    ADD CONSTRAINT #{@pathway_fkey}
    FOREIGN KEY (organization_id, gtfs_version_id, pathway_id)
    REFERENCES #{qualified_table(:pathways)} (organization_id, gtfs_version_id, pathway_id)
    ON DELETE RESTRICT
    """)
  end

  def down do
    drop table(:pathway_evolutions)
  end

  defp qualified_table(table) do
    case prefix() do
      nil -> Atom.to_string(table)
      schema -> ~s("#{schema}".#{table})
    end
  end
end
