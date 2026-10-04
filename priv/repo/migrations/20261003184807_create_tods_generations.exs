defmodule GtfsPlanner.Repo.Migrations.CreateTodsGenerations do
  use Ecto.Migration

  def change do
    # The durable receipt of one completed TODS generator request. It records
    # what a scoped request produced; it is never a queue of pending work and it
    # never holds planning data that belongs to the domain tables.
    create table(:tods_generations, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :organization_id, references(:organizations, type: :binary_id, on_delete: :delete_all),
        null: false

      add :gtfs_version_id, references(:gtfs_versions, type: :binary_id, on_delete: :delete_all),
        null: false

      # The actor is provenance, not ownership: removing a user leaves the receipt
      # readable instead of destroying the record of a generation.
      add :actor_id, references(:users, type: :binary_id, on_delete: :nilify_all)

      # The scoped request identity. Uniqueness is decided here rather than in
      # application code, so two concurrent requests carrying one token can only
      # ever leave one receipt behind.
      add :request_id, :uuid, null: false

      add :normalized_inputs, :map, null: false, default: %{}
      add :source_fingerprint, :string, null: false
      add :created_ids, :map, null: false, default: %{}
      add :summary, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:tods_generations, [:organization_id, :gtfs_version_id, :request_id],
             name: :tods_generations_scope_request_id_index
           )

    # A receipt may only name a version of its own organization. `gtfs_versions`
    # carries a unique index on `(id, organization_id)`, so the composite key
    # below can be enforced instead of trusting the writer's scoping.
    execute(
      """
      ALTER TABLE #{qualified_table(:tods_generations)}
      ADD CONSTRAINT tods_generations_version_organization_fkey
      FOREIGN KEY (gtfs_version_id, organization_id)
      REFERENCES #{qualified_table(:gtfs_versions)} (id, organization_id)
      ON DELETE CASCADE
      """,
      """
      ALTER TABLE #{qualified_table(:tods_generations)}
      DROP CONSTRAINT tods_generations_version_organization_fkey
      """
    )
  end

  defp qualified_table(table) do
    case prefix() do
      nil -> Atom.to_string(table)
      schema -> ~s("#{String.replace(schema, "\"", "\"\"")}".#{table})
    end
  end
end
