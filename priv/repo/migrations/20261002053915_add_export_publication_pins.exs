defmodule GtfsPlanner.Repo.Migrations.AddExportPublicationPins do
  use Ecto.Migration

  @slot_check "feed_publication_pins_slot_check"

  # A publication pin protects the private bytes of one ready export run while a
  # public generation is being reviewed, validated and uploaded. It is a lease,
  # not a download claim: it never touches `download_count` and it is released
  # once the remote payload receipt is durable.
  #
  # `export_run_id` is ON DELETE RESTRICT on purpose. `gtfs_export_runs` is itself
  # ON DELETE CASCADE from `gtfs_versions`, so this foreign key is what stops a
  # source-version deletion from cascading the pinned artifact away mid-upload.
  def change do
    create table(:feed_publication_pins, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :export_run_id, references(:gtfs_export_runs, type: :binary_id, on_delete: :restrict),
        null: false

      # The tenant a pin belongs to, carried on the row and constrained to the
      # same organization as the run it names.
      add :organization_id, :binary_id, null: false

      add :slot, :string, null: false
      add :owner_id, :string, null: false
      add :pin_token, :binary_id, null: false
      add :expires_at, :utc_datetime_usec, null: false

      timestamps(type: :utc_datetime_usec)
    end

    # One run carries at most one publication pin. A second owner is refused
    # rather than allowed to replace the live claim.
    create unique_index(:feed_publication_pins, [:export_run_id])
    create unique_index(:feed_publication_pins, [:pin_token])

    create constraint(:feed_publication_pins, @slot_check, check: "slot IN ('main', 'flex')")

    # `id` is already the primary key, so this unique index only exists to give
    # the composite tenant-correct foreign key below a referable target.
    create unique_index(:gtfs_export_runs, [:id, :organization_id])

    execute(
      """
      ALTER TABLE #{qualified_table(:feed_publication_pins)}
      ADD CONSTRAINT feed_publication_pins_run_owner_fkey
      FOREIGN KEY (export_run_id, organization_id)
      REFERENCES #{qualified_table(:gtfs_export_runs)} (id, organization_id)
      ON DELETE RESTRICT
      """,
      """
      ALTER TABLE #{qualified_table(:feed_publication_pins)}
      DROP CONSTRAINT feed_publication_pins_run_owner_fkey
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
