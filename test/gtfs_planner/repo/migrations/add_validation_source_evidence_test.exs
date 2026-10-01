defmodule GtfsPlanner.Repo.Migrations.AddValidationSourceEvidenceTest do
  @moduledoc """
  The additive provenance migration applied in an isolated schema.

  The isolated prefix holds a populated legacy row, so the evidence is that a
  retained run keeps its stored report JSON and provenance stays unknown; the
  public schema is never touched here.
  """

  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL
  alias Ecto.Adapters.SQL.Sandbox
  alias Ecto.Migrator
  alias GtfsPlanner.Repo

  @migration_path Path.expand(
                    "../../../../priv/repo/migrations/20261001212112_add_validation_source_evidence.exs",
                    __DIR__
                  )
  Code.require_file(@migration_path)

  @migration_version 20_261_001_212_112

  alias GtfsPlanner.Repo.Migrations.AddValidationSourceEvidence, as: Migration

  @legacy_notices [
    %{
      "code" => "missing_required_field",
      "severity" => "ERROR",
      "total_notices" => 4,
      "notices" => [%{"filename" => "stops.txt", "fieldName" => "stop_id"}]
    }
  ]

  setup_all do
    Sandbox.mode(Repo, :auto)
    on_exit(fn -> Sandbox.mode(Repo, :manual) end)
    :ok
  end

  test "adds three nullable provenance columns without rewriting a populated legacy row" do
    prefix = setup_prefix()
    id = insert_legacy_run(prefix)

    Migrator.up(Repo, @migration_version, Migration, prefix: prefix, log: false)

    assert provenance_columns(prefix) == [
             ["checked_export_profile", "jsonb", "YES"],
             ["checked_zip_sha256", "character varying", "YES"],
             ["validator_version", "character varying", "YES"]
           ]

    assert [
             ["completed"],
             [errors],
             [warnings],
             [infos],
             [result_json],
             [digest],
             [profile],
             [version]
           ] =
             select_legacy_run(prefix, id)

    assert errors == 4
    assert warnings == 2
    assert infos == 0
    # jsonb comes back as raw bytes over a plain query, so decode before comparing.
    assert Jason.decode!(result_json) == %{"notices" => @legacy_notices}
    assert digest == nil
    assert profile == nil
    assert version == nil

    Migrator.down(Repo, @migration_version, Migration, prefix: prefix, log: false)

    assert provenance_columns(prefix) == []
  end

  defp setup_prefix do
    prefix = "test_add_validation_source_evidence_#{System.unique_integer([:positive])}"
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
        errors_count integer DEFAULT 0 NOT NULL,
        warnings_count integer DEFAULT 0 NOT NULL,
        infos_count integer DEFAULT 0 NOT NULL,
        result_json jsonb
      )
      """,
      []
    )

    prefix
  end

  defp insert_legacy_run(prefix) do
    id = Ecto.UUID.generate()

    SQL.query!(
      Repo,
      """
      INSERT INTO "#{prefix}".gtfs_validation_runs
        (id, organization_id, gtfs_version_id, run_type, status, errors_count, warnings_count, infos_count, result_json)
      VALUES ($1, $2, $3, 'mobility_data', 'completed', 4, 2, 0, $4::jsonb)
      """,
      [
        Ecto.UUID.dump!(id),
        Ecto.UUID.dump!(Ecto.UUID.generate()),
        Ecto.UUID.dump!(Ecto.UUID.generate()),
        Jason.encode!(%{"notices" => @legacy_notices})
      ]
    )

    id
  end

  defp select_legacy_run(prefix, id) do
    SQL.query!(
      Repo,
      """
      SELECT status, errors_count, warnings_count, infos_count, result_json,
             checked_zip_sha256, checked_export_profile, validator_version
      FROM "#{prefix}".gtfs_validation_runs
      WHERE id = $1
      """,
      [Ecto.UUID.dump!(id)]
    ).rows
  end

  defp provenance_columns(prefix) do
    SQL.query!(
      Repo,
      """
      SELECT column_name, data_type, is_nullable
      FROM information_schema.columns
      WHERE table_schema = $1
        AND table_name = 'gtfs_validation_runs'
        AND column_name IN ('checked_zip_sha256', 'checked_export_profile', 'validator_version')
      ORDER BY column_name
      """,
      [prefix]
    ).rows
  end
end
