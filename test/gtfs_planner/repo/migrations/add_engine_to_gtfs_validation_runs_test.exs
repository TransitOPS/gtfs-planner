defmodule GtfsPlanner.Repo.Migrations.AddEngineToGtfsValidationRunsTest do
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL
  alias Ecto.Adapters.SQL.Sandbox
  alias Ecto.Migrator
  alias GtfsPlanner.Repo

  @migration_path Path.expand(
                    "../../../../priv/repo/migrations/20260728024342_add_engine_to_gtfs_validation_runs.exs",
                    __DIR__
                  )
  Code.require_file(@migration_path)

  @migration_version 20_260_728_024_342

  alias GtfsPlanner.Repo.Migrations.AddEngineToGtfsValidationRuns, as: Migration

  setup_all do
    Sandbox.mode(Repo, :auto)
    on_exit(fn -> Sandbox.mode(Repo, :manual) end)
    :ok
  end

  test "adds nullable engine metadata and the active station reachability index in an isolated prefix" do
    prefix = setup_prefix()

    Migrator.up(Repo, @migration_version, Migration, prefix: prefix, log: false)

    assert columns(prefix, "gtfs_validation_runs") |> Enum.sort() ==
             [
               "engine",
               "gtfs_version_id",
               "id",
               "organization_id",
               "result_json",
               "result_schema_version",
               "run_type",
               "status"
             ]

    assert index_exists?(prefix, "gtfs_validation_runs_active_station_reachability_index")

    Migrator.down(Repo, @migration_version, Migration, prefix: prefix, log: false)

    refute "engine" in columns(prefix, "gtfs_validation_runs")
    refute index_exists?(prefix, "gtfs_validation_runs_active_station_reachability_index")
  end

  defp setup_prefix do
    prefix = "test_add_engine_#{System.unique_integer([:positive])}"
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
        status varchar(255) NOT NULL,
        result_json jsonb
      )
      """,
      []
    )

    prefix
  end

  defp columns(prefix, table) do
    %{rows: rows} =
      SQL.query!(
        Repo,
        "SELECT column_name FROM information_schema.columns WHERE table_schema = $1 AND table_name = $2",
        [prefix, table]
      )

    List.flatten(rows)
  end

  defp index_exists?(prefix, index) do
    %{rows: rows} =
      SQL.query!(Repo, "SELECT 1 FROM pg_indexes WHERE schemaname = $1 AND indexname = $2", [
        prefix,
        index
      ])

    rows != []
  end
end
