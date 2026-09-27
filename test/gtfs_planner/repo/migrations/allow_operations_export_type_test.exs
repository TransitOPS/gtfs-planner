defmodule GtfsPlanner.Repo.Migrations.AllowOperationsExportTypeTest do
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL
  alias Ecto.Adapters.SQL.Sandbox
  alias Ecto.Migrator
  alias GtfsPlanner.Repo

  @create_migration_glob "../../../../priv/repo/migrations/*_create_gtfs_export_runs.exs"

  @create_migration_path @create_migration_glob
                         |> Path.expand(__DIR__)
                         |> Path.wildcard()
                         |> List.first()

  @create_migration_version @create_migration_path
                            |> Path.basename()
                            |> String.split("_", parts: 2)
                            |> hd()
                            |> String.to_integer()

  Code.require_file(@create_migration_path)

  alias GtfsPlanner.Repo.Migrations.CreateGtfsExportRuns, as: CreateMigration

  @migration_glob "../../../../priv/repo/migrations/*_allow_operations_export_type.exs"

  @migration_path @migration_glob
                  |> Path.expand(__DIR__)
                  |> Path.wildcard()
                  |> List.first()

  @migration_version @migration_path
                     |> Path.basename()
                     |> String.split("_", parts: 2)
                     |> hd()
                     |> String.to_integer()

  Code.require_file(@migration_path)

  alias GtfsPlanner.Repo.Migrations.AllowOperationsExportType, as: Migration

  @state_check "gtfs_export_runs_state_check"
  @now ~U[2026-09-27 00:00:00.000000Z]

  setup_all do
    Sandbox.mode(Repo, :auto)
    on_exit(fn -> Sandbox.mode(Repo, :manual) end)
    :ok
  end

  setup do
    schema = setup_prefix()
    organization_id = insert_organization(schema)
    version_id = insert_version(schema, organization_id)

    Migrator.up(Repo, @create_migration_version, CreateMigration, prefix: schema, log: false)
    original_definition = state_check_definition(schema)

    Migrator.up(Repo, @migration_version, Migration, prefix: schema, log: false)

    %{
      schema: schema,
      organization_id: organization_id,
      version_id: version_id,
      original_definition: original_definition
    }
  end

  describe "up" do
    test "widens only the export-type clause and keeps the state and phase clauses", context do
      definition = state_check_definition(context.schema)

      assert definition =~
               "((export_type)::text = ANY (ARRAY['full'::text, 'pathways'::text, 'operations'::text]))"

      assert definition =~
               "((state)::text = ANY (ARRAY['pending'::text, 'building'::text, 'ready'::text, " <>
                 "'failed'::text, 'interrupted'::text, 'cancelled'::text, 'expired'::text]))"

      assert definition =~
               "((phase IS NULL) OR ((phase)::text = ANY (ARRAY['preflight'::text, " <>
                 "'packaging'::text, 'publishing'::text, 'cleanup'::text])))"

      # Removing the added type reproduces the shipped expression exactly, so the
      # rewrite cannot have dropped or reordered a state or phase clause.
      assert String.replace(definition, ", 'operations'::text", "") ==
               context.original_definition
    end

    test "accepts operations rows and still rejects an unknown type, state, and phase", context do
      run_id = insert_run!(context, export_type: "operations")

      assert operations_run_ids(context) == [run_id]
      assert is_binary(insert_run!(context, export_type: "pathways"))

      assert_state_check_violation(fn -> insert_run!(context, export_type: "crew") end)

      assert_state_check_violation(fn ->
        insert_run!(context, export_type: "operations", state: "unknown")
      end)

      assert_state_check_violation(fn ->
        insert_run!(context, export_type: "operations", phase: "unknown")
      end)
    end
  end

  describe "down" do
    test "refuses a destructive rollback while operations runs exist and leaves every row",
         context do
      pending_id = insert_run!(context, export_type: "operations")

      other_version_id = insert_version(context.schema, context.organization_id)
      other_id = insert_run!(%{context | version_id: other_version_id}, export_type: "operations")

      definition = state_check_definition(context.schema)

      assert_raise RuntimeError, rollback_refusal(2), fn ->
        Migrator.down(Repo, @migration_version, Migration, prefix: context.schema, log: false)
      end

      assert operations_run_ids(context) == [pending_id]
      assert operations_run_ids(%{context | version_id: other_version_id}) == [other_id]

      assert Enum.sort(all_operations_run_ids(context.schema)) ==
               Enum.sort([pending_id, other_id])

      assert state_check_definition(context.schema) == definition
      assert migrated_versions(context.schema) == [@create_migration_version, @migration_version]

      assert_raise RuntimeError, rollback_refusal(2), fn ->
        Migrator.down(Repo, @migration_version, Migration, prefix: context.schema, log: false)
      end
    end

    test "restores the original gate when no operations run exists", context do
      assert operations_run_ids(context) == []

      Migrator.down(Repo, @migration_version, Migration, prefix: context.schema, log: false)

      assert state_check_definition(context.schema) == context.original_definition
      assert migrated_versions(context.schema) == [@create_migration_version]

      assert is_binary(insert_run!(context, export_type: "pathways"))

      assert_state_check_violation(fn -> insert_run!(context, export_type: "operations") end)

      assert_state_check_violation(fn ->
        insert_run!(context, export_type: "full", state: "unknown")
      end)

      assert_state_check_violation(fn ->
        insert_run!(context, export_type: "full", phase: "unknown")
      end)
    end
  end

  defp setup_prefix do
    schema = "test_operations_export_type_#{System.unique_integer([:positive])}"
    SQL.query!(Repo, ~s|CREATE SCHEMA "#{schema}"|, [])

    on_exit(fn ->
      SQL.query!(Repo, ~s|DROP SCHEMA IF EXISTS "#{schema}" CASCADE|, [])
    end)

    SQL.query!(
      Repo,
      """
      CREATE TABLE "#{schema}".organizations (
        id uuid PRIMARY KEY, name varchar(255) NOT NULL,
        inserted_at timestamp NOT NULL DEFAULT now(), updated_at timestamp NOT NULL DEFAULT now()
      )
      """,
      []
    )

    SQL.query!(
      Repo,
      """
      CREATE TABLE "#{schema}".gtfs_versions (
        id uuid PRIMARY KEY, organization_id uuid NOT NULL REFERENCES "#{schema}".organizations(id),
        name varchar(255) NOT NULL, inserted_at timestamp(6) NOT NULL, updated_at timestamp(6) NOT NULL
      )
      """,
      []
    )

    SQL.query!(
      Repo,
      ~s|CREATE UNIQUE INDEX gtfs_versions_organization_id_id_index ON "#{schema}".gtfs_versions (organization_id, id)|,
      []
    )

    schema
  end

  defp insert_organization(schema) do
    id = Ecto.UUID.generate()

    SQL.query!(
      Repo,
      ~s|INSERT INTO "#{schema}".organizations (id, name) VALUES ($1, $2)|,
      [dump(id), "Test"]
    )

    id
  end

  defp insert_version(schema, organization_id) do
    id = Ecto.UUID.generate()

    SQL.query!(
      Repo,
      """
      INSERT INTO "#{schema}".gtfs_versions (id, organization_id, name, inserted_at, updated_at)
      VALUES ($1, $2, $3, $4, $4)
      """,
      [dump(id), dump(organization_id), "Version", @now]
    )

    id
  end

  defp insert_run!(context, opts) do
    id = Keyword.get(opts, :id, Ecto.UUID.generate())

    SQL.query!(
      Repo,
      """
      INSERT INTO "#{context.schema}".gtfs_export_runs (
        id, export_type, state, phase, organization_id, gtfs_version_id, inserted_at, updated_at
      ) VALUES ($1, $2, $3, $4, $5, $6, $7, $7)
      """,
      [
        dump(id),
        Keyword.get(opts, :export_type, "full"),
        Keyword.get(opts, :state, "pending"),
        Keyword.get(opts, :phase),
        dump(context.organization_id),
        dump(context.version_id),
        @now
      ]
    )

    id
  end

  defp operations_run_ids(context) do
    %{rows: rows} =
      SQL.query!(
        Repo,
        """
        SELECT id FROM "#{context.schema}".gtfs_export_runs
        WHERE export_type = 'operations' AND organization_id = $1 AND gtfs_version_id = $2
        ORDER BY id
        """,
        [dump(context.organization_id), dump(context.version_id)]
      )

    Enum.map(rows, fn [id] -> Ecto.UUID.load!(id) end)
  end

  defp all_operations_run_ids(schema) do
    %{rows: rows} =
      SQL.query!(
        Repo,
        ~s|SELECT id FROM "#{schema}".gtfs_export_runs WHERE export_type = 'operations' ORDER BY id|,
        []
      )

    Enum.map(rows, fn [id] -> Ecto.UUID.load!(id) end)
  end

  defp state_check_definition(schema) do
    %{rows: [[definition]]} =
      SQL.query!(
        Repo,
        """
        SELECT pg_get_constraintdef(con.oid) FROM pg_constraint con
        JOIN pg_class rel ON rel.oid = con.conrelid
        JOIN pg_namespace nsp ON nsp.oid = rel.relnamespace
        WHERE nsp.nspname = $1 AND rel.relname = 'gtfs_export_runs' AND con.conname = $2
        """,
        [schema, @state_check]
      )

    definition
  end

  defp migrated_versions(schema) do
    %{rows: rows} =
      SQL.query!(Repo, ~s|SELECT version FROM "#{schema}".schema_migrations ORDER BY version|, [])

    List.flatten(rows)
  end

  defp rollback_refusal(count) do
    "Cannot roll back allow_operations_export_type: #{count} export runs use export_type " <>
      "'operations'. Keep this migration and fix forward."
  end

  defp assert_state_check_violation(fun) do
    error = assert_raise(Postgrex.Error, fun)
    assert error.postgres.code == :check_violation
    assert error.postgres.constraint == @state_check
  end

  defp dump(uuid), do: Ecto.UUID.dump!(uuid)
end
