defmodule GtfsPlanner.Repo.Migrations.DropOtpGtfsArtifactsTest do
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL
  alias Ecto.Adapters.SQL.Sandbox
  alias Ecto.Migrator
  alias GtfsPlanner.Repo

  @migration_path Path.expand(
                    "../../../../priv/repo/migrations/20260728105652_drop_otp_gtfs_artifacts.exs",
                    __DIR__
                  )
  Code.require_file(@migration_path)

  @migration_version @migration_path
                     |> Path.basename()
                     |> String.split("_", parts: 2)
                     |> hd()
                     |> String.to_integer()

  alias GtfsPlanner.Repo.Migrations.DropOtpGtfsArtifacts, as: Migration

  setup_all do
    Sandbox.mode(Repo, :auto)
    on_exit(fn -> Sandbox.mode(Repo, :manual) end)
    :ok
  end

  test "up/down/up removes and exactly restores OTP artifacts in an isolated prefix" do
    prefix = setup_prefix()

    assert table_exists?(prefix, "otp_gtfs_artifacts")
    assert index_exists?(prefix, "otp_gtfs_artifacts_org_version_unique_index")

    Migrator.up(Repo, @migration_version, Migration, prefix: prefix, log: false)
    refute table_exists?(prefix, "otp_gtfs_artifacts")

    Migrator.down(Repo, @migration_version, Migration, prefix: prefix, log: false)
    assert table_exists?(prefix, "otp_gtfs_artifacts")
    assert index_exists?(prefix, "otp_gtfs_artifacts_org_version_unique_index")

    assert columns(prefix) == [
             "content_hash",
             "file_size_bytes",
             "gtfs_version_id",
             "id",
             "inserted_at",
             "manifest_json",
             "organization_id",
             "updated_at",
             "zip_path"
           ]

    Migrator.up(Repo, @migration_version, Migration, prefix: prefix, log: false)
    refute table_exists?(prefix, "otp_gtfs_artifacts")
  end

  defp setup_prefix do
    prefix = "test_drop_otp_artifacts_#{System.unique_integer([:positive])}"
    SQL.query!(Repo, ~s|CREATE SCHEMA "#{prefix}"|, [])

    on_exit(fn -> SQL.query!(Repo, ~s|DROP SCHEMA IF EXISTS "#{prefix}" CASCADE|, []) end)

    SQL.query!(Repo, "CREATE TABLE \"#{prefix}\".organizations (id uuid PRIMARY KEY)", [])
    SQL.query!(Repo, "CREATE TABLE \"#{prefix}\".gtfs_versions (id uuid PRIMARY KEY)", [])

    SQL.query!(
      Repo,
      """
      CREATE TABLE "#{prefix}".otp_gtfs_artifacts (
        id uuid PRIMARY KEY,
        organization_id uuid NOT NULL REFERENCES "#{prefix}".organizations(id) ON DELETE CASCADE,
        gtfs_version_id uuid NOT NULL REFERENCES "#{prefix}".gtfs_versions(id) ON DELETE CASCADE,
        zip_path varchar(255) NOT NULL,
        content_hash varchar(255) NOT NULL,
        file_size_bytes integer NOT NULL,
        manifest_json jsonb NOT NULL,
        inserted_at timestamp(6) NOT NULL,
        updated_at timestamp(6) NOT NULL
      )
      """,
      []
    )

    SQL.query!(
      Repo,
      "CREATE UNIQUE INDEX \"otp_gtfs_artifacts_org_version_unique_index\" ON \"#{prefix}\".otp_gtfs_artifacts (organization_id, gtfs_version_id)",
      []
    )

    prefix
  end

  defp table_exists?(prefix, table) do
    %{rows: rows} =
      SQL.query!(
        Repo,
        "SELECT 1 FROM information_schema.tables WHERE table_schema = $1 AND table_name = $2",
        [
          prefix,
          table
        ]
      )

    rows != []
  end

  defp index_exists?(prefix, index) do
    %{rows: rows} =
      SQL.query!(Repo, "SELECT 1 FROM pg_indexes WHERE schemaname = $1 AND indexname = $2", [
        prefix,
        index
      ])

    rows != []
  end

  defp columns(prefix) do
    %{rows: rows} =
      SQL.query!(
        Repo,
        "SELECT column_name FROM information_schema.columns WHERE table_schema = $1 AND table_name = 'otp_gtfs_artifacts' ORDER BY column_name",
        [prefix]
      )

    List.flatten(rows)
  end
end
