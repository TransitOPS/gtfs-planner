defmodule GtfsPlanner.Repo.Migrations.AddValidationRunLeasesTest do
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL
  alias Ecto.Adapters.SQL.Sandbox
  alias Ecto.Migrator
  alias GtfsPlanner.Repo
  alias GtfsPlanner.Validations.ValidationRun

  @migration_path Path.expand(
                    "../../../../priv/repo/migrations/20261001042032_add_validation_run_leases.exs",
                    __DIR__
                  )
  Code.require_file(@migration_path)

  @migration_version 20_261_001_042_032

  alias GtfsPlanner.Repo.Migrations.AddValidationRunLeases, as: Migration

  @started_at ~U[2026-10-01 04:00:00.000000Z]
  @lease_expires_at ~U[2026-10-01 04:05:00.000000Z]

  @lease_columns [
    ["lease_expires_at", "timestamp without time zone", "YES", 6],
    ["lease_token", "uuid", "YES", nil]
  ]

  setup_all do
    Sandbox.mode(Repo, :auto)
    on_exit(fn -> Sandbox.mode(Repo, :manual) end)
    :ok
  end

  describe "migration" do
    test "adds a nullable uuid lease_token and a nullable microsecond lease_expires_at" do
      prefix = setup_prefix()

      Migrator.up(Repo, @migration_version, Migration, prefix: prefix, log: false)

      assert lease_columns(prefix) == @lease_columns
    end

    test "leaves lease values null on rows inserted before the migration" do
      prefix = setup_prefix()
      id = insert_run(prefix)

      Migrator.up(Repo, @migration_version, Migration, prefix: prefix, log: false)

      assert %{rows: [[nil, nil]]} =
               SQL.query!(
                 Repo,
                 ~s|SELECT lease_token, lease_expires_at FROM "#{prefix}".gtfs_validation_runs WHERE id = $1|,
                 [Ecto.UUID.dump!(id)]
               )
    end

    test "is applied to the migrated gtfs_validation_runs table" do
      assert lease_columns("public") == @lease_columns
    end
  end

  describe "ValidationRun.changeset/2" do
    test "ignores submitted lease_token and lease_expires_at" do
      changeset =
        ValidationRun.changeset(%ValidationRun{}, %{
          run_type: "mobility_data",
          status: "started",
          started_at: @started_at,
          lease_token: Ecto.UUID.generate(),
          lease_expires_at: @lease_expires_at
        })

      assert changeset.valid?

      assert changeset.changes == %{
               run_type: "mobility_data",
               status: "started",
               started_at: @started_at
             }
    end
  end

  describe "ValidationRun.system_changeset/2" do
    test "casts lease_token and lease_expires_at with the lifecycle status" do
      token = Ecto.UUID.generate()

      changeset =
        ValidationRun.system_changeset(started_run(), %{
          status: "running",
          lease_token: token,
          lease_expires_at: @lease_expires_at
        })

      assert changeset.valid?

      assert changeset.changes == %{
               status: "running",
               lease_token: token,
               lease_expires_at: @lease_expires_at
             }
    end

    test "rejects an unknown status" do
      changeset = ValidationRun.system_changeset(started_run(), %{status: "paused"})

      refute changeset.valid?
      assert {"is invalid", _opts} = changeset.errors[:status]
    end
  end

  defp started_run do
    %ValidationRun{run_type: "mobility_data", status: "started", started_at: @started_at}
  end

  defp setup_prefix do
    prefix = "test_add_validation_run_leases_#{System.unique_integer([:positive])}"
    SQL.query!(Repo, ~s|CREATE SCHEMA "#{prefix}"|, [])
    on_exit(fn -> SQL.query!(Repo, ~s|DROP SCHEMA IF EXISTS "#{prefix}" CASCADE|, []) end)

    SQL.query!(
      Repo,
      """
      CREATE TABLE "#{prefix}".gtfs_validation_runs (
        id uuid PRIMARY KEY,
        organization_id uuid NOT NULL,
        gtfs_version_id uuid NOT NULL,
        run_type varchar(255) NOT NULL,
        status varchar(255) NOT NULL
      )
      """,
      []
    )

    prefix
  end

  defp insert_run(prefix) do
    id = Ecto.UUID.generate()

    SQL.query!(
      Repo,
      """
      INSERT INTO "#{prefix}".gtfs_validation_runs
        (id, organization_id, gtfs_version_id, run_type, status)
      VALUES ($1, $2, $3, 'mobility_data', 'completed')
      """,
      [
        Ecto.UUID.dump!(id),
        Ecto.UUID.dump!(Ecto.UUID.generate()),
        Ecto.UUID.dump!(Ecto.UUID.generate())
      ]
    )

    id
  end

  defp lease_columns(schema) do
    %{rows: rows} =
      SQL.query!(
        Repo,
        """
        SELECT column_name, data_type, is_nullable, datetime_precision
        FROM information_schema.columns
        WHERE table_schema = $1
          AND table_name = 'gtfs_validation_runs'
          AND column_name IN ('lease_token', 'lease_expires_at')
        ORDER BY column_name
        """,
        [schema]
      )

    rows
  end
end
