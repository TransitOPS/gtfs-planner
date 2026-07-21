defmodule GtfsPlanner.Repo.Migrations.CreateGtfsExportRunsTest do
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL
  alias Ecto.Adapters.SQL.Sandbox
  alias GtfsPlanner.Repo

  setup_all do
    Sandbox.mode(Repo, :auto)
    on_exit(fn -> Sandbox.mode(Repo, :manual) end)
    :ok
  end

  @migration_glob "../../../../priv/repo/migrations/*_create_gtfs_export_runs.exs"
  @migration_path Path.expand(@migration_glob, __DIR__) |> Path.wildcard() |> List.first()

  Code.require_file(@migration_path)

  @migration_version @migration_path
                     |> Path.basename()
                     |> String.split("_", parts: 2)
                     |> hd()
                     |> String.to_integer()

  alias GtfsPlanner.Repo.Migrations.CreateGtfsExportRuns, as: Migration

  @now ~U[2026-07-21 00:00:00.000000Z]
  @terminal_states ~w(ready failed interrupted cancelled expired)

  describe "migration constraints and scoped identities" do
    setup do
      schema = setup_prefix()
      organization_id = insert_organization(schema)
      version_id = insert_version(schema, organization_id)
      migrate_up(schema)
      %{schema: schema, organization_id: organization_id, version_id: version_id}
    end

    test "creates the export table, active-scope index, constraints, and composite scope key",
         context do
      assert table_exists?(context.schema, "gtfs_export_runs")

      for index <- ~w(
            gtfs_export_runs_org_version_state_index
            gtfs_export_runs_one_active_per_scope_type_index
          ) do
        assert index_exists?(context.schema, index)
      end

      for constraint <- ~w(
            gtfs_export_runs_state_check
            gtfs_export_runs_lease_check
            gtfs_export_runs_artifact_check
            gtfs_export_runs_timestamp_check
            gtfs_export_runs_progress_check
            gtfs_export_runs_download_claim_check
            gtfs_export_runs_organization_version_fkey
          ) do
        assert constraint in constraint_names(context.schema, "gtfs_export_runs")
      end
    end

    test "rejects invalid lifecycle, lease, artifact, progress, download claim, and version scope",
         context do
      assert_constraint_violation(fn -> insert_run!(context, export_type: "unknown") end)
      assert_constraint_violation(fn -> insert_run!(context, state: "unknown") end)
      assert_constraint_violation(fn -> insert_run!(context, phase: "unknown") end)
      assert_constraint_violation(fn -> insert_run!(context, state: "building", lease: false) end)
      assert_constraint_violation(fn -> insert_run!(context, state: "ready", lease: true) end)

      assert_constraint_violation(fn ->
        insert_run!(context, state: "ready", artifact: :missing)
      end)

      assert_constraint_violation(fn ->
        insert_run!(context, state: "ready", artifact: :bad_sha)
      end)

      assert_constraint_violation(fn -> insert_run!(context, artifact_size: -1) end)
      assert_constraint_violation(fn -> insert_run!(context, progress: {2, 1}) end)
      assert_constraint_violation(fn -> insert_run!(context, download_claimed: true) end)

      foreign_version = insert_version(context.schema, insert_organization(context.schema))

      assert_constraint_violation(fn ->
        insert_run!(%{context | version_id: foreign_version})
      end)
    end

    test "allows one active run per scope and export type while retaining terminal history",
         context do
      insert_run!(context, export_type: "full")

      assert_constraint_violation(fn ->
        insert_run!(context, export_type: "full", state: "building")
      end)

      insert_run!(context, export_type: "pathways")

      terminal_context = %{context | version_id: Ecto.UUID.generate()}
      insert_version(context.schema, context.organization_id, terminal_context.version_id)
      insert_run!(terminal_context, state: "ready")
      insert_run!(terminal_context, state: "failed")
    end
  end

  defp setup_prefix do
    schema = "test_export_runs_#{System.unique_integer([:positive])}"
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

  defp insert_version(schema, organization_id, id \\ Ecto.UUID.generate()) do
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

  defp insert_run!(context, opts \\ []) do
    state = Keyword.get(opts, :state, "pending")
    export_type = Keyword.get(opts, :export_type, "full")
    leased? = Keyword.get(opts, :lease, state == "building")
    finished? = Keyword.get(opts, :finished, state in @terminal_states)
    {current, total} = Keyword.get(opts, :progress, {nil, nil})
    artifact = Keyword.get(opts, :artifact, if(state == "ready", do: :complete, else: :none))

    {artifact_key, artifact_filename, artifact_sha256, artifact_size, artifact_expires_at} =
      artifact_values(artifact, Keyword.get(opts, :artifact_size, 32))

    artifact_size =
      if Keyword.has_key?(opts, :artifact_size),
        do: Keyword.fetch!(opts, :artifact_size),
        else: artifact_size

    SQL.query!(
      Repo,
      """
      INSERT INTO "#{context.schema}".gtfs_export_runs (
        id, export_type, state, phase, progress_current, progress_total, warnings, lease_generation,
        lease_token, lease_expires_at, artifact_key, artifact_filename, artifact_sha256,
        artifact_size_bytes, artifact_expires_at, download_claimed_until, download_count,
        started_at, finished_at, organization_id, gtfs_version_id, inserted_at, updated_at
      ) VALUES (
        $1, $2, $3, $4, $5, $6, $7, $8,
        $9, $10, $11, $12, $13,
        $14, $15, $16, $17,
        $18, $19, $20, $21, $22, $22
      )
      """,
      [
        dump(Ecto.UUID.generate()),
        export_type,
        state,
        Keyword.get(opts, :phase),
        current,
        total,
        [],
        0,
        if(leased?, do: dump(Ecto.UUID.generate())),
        if(leased?, do: @now),
        artifact_key,
        artifact_filename,
        artifact_sha256,
        artifact_size,
        artifact_expires_at,
        if(Keyword.get(opts, :download_claimed, false), do: @now),
        0,
        if(state == "pending", do: nil, else: @now),
        if(finished?, do: @now),
        dump(context.organization_id),
        dump(context.version_id),
        @now
      ]
    )
  end

  defp artifact_values(:complete, size),
    do: {"exports/run/archive.zip", "archive.zip", String.duplicate("a", 64), size, @now}

  defp artifact_values(:missing, _size), do: {nil, nil, nil, nil, nil}

  defp artifact_values(:bad_sha, size),
    do: {"exports/run/archive.zip", "archive.zip", "bad", size, @now}

  defp artifact_values(:none, _size), do: {nil, nil, nil, nil, nil}

  defp migrate_up(schema),
    do: Ecto.Migrator.up(Repo, @migration_version, Migration, prefix: schema, log: false)

  defp assert_constraint_violation(fun), do: assert_raise(Postgrex.Error, fun)

  defp table_exists?(schema, table) do
    %{rows: rows} =
      SQL.query!(
        Repo,
        "SELECT 1 FROM information_schema.tables WHERE table_schema = $1 AND table_name = $2",
        [schema, table]
      )

    rows != []
  end

  defp index_exists?(schema, index) do
    %{rows: rows} =
      SQL.query!(
        Repo,
        "SELECT 1 FROM pg_indexes WHERE schemaname = $1 AND indexname = $2",
        [schema, index]
      )

    rows != []
  end

  defp constraint_names(schema, table) do
    %{rows: rows} =
      SQL.query!(
        Repo,
        """
        SELECT con.conname FROM pg_constraint con
        JOIN pg_class rel ON rel.oid = con.conrelid
        JOIN pg_namespace nsp ON nsp.oid = rel.relnamespace
        WHERE nsp.nspname = $1 AND rel.relname = $2
        """,
        [schema, table]
      )

    List.flatten(rows)
  end

  defp dump(uuid), do: Ecto.UUID.dump!(uuid)
end
