defmodule GtfsPlanner.Repo.Migrations.CreateGtfsChangeRunsTest do
  use ExUnit.Case, async: false

  alias GtfsPlanner.Repo

  setup_all do
    Ecto.Adapters.SQL.Sandbox.mode(Repo, :auto)
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.mode(Repo, :manual) end)
    :ok
  end

  @migration_glob "../../../../priv/repo/migrations/*_create_gtfs_change_runs.exs"
  @migration_path Path.expand(@migration_glob, __DIR__) |> Path.wildcard() |> List.first()

  Code.require_file(@migration_path)

  @migration_version @migration_path
                     |> Path.basename()
                     |> String.split("_", parts: 2)
                     |> hd()
                     |> String.to_integer()

  alias GtfsPlanner.Repo.Migrations.CreateGtfsChangeRuns, as: Migration

  @now ~U[2026-07-21 00:00:00.000000Z]
  @lease_states ~w(computing applying)
  @terminal_states ~w(partial completed failed interrupted cancelled expired)

  describe "migration constraints and scoped identities" do
    setup do
      schema = setup_prefix()
      organization_id = insert_organization(schema)
      version_id = insert_version(schema, organization_id)
      migrate_up(schema)
      %{schema: schema, organization_id: organization_id, version_id: version_id}
    end

    test "creates both tables, required indexes, checks, and cross-scope key", context do
      assert table_exists?(context.schema, "gtfs_change_runs")
      assert table_exists?(context.schema, "gtfs_change_decisions")

      for index <- ~w(
            gtfs_change_runs_org_version_state_index
            gtfs_change_runs_one_nonterminal_per_scope_index
            gtfs_change_decisions_change_run_decision_id_index
            gtfs_change_decisions_run_status_action_index
          ) do
        assert index_exists?(context.schema, index)
      end

      for constraint <- ~w(
            gtfs_change_runs_state_check
            gtfs_change_runs_lease_check
            gtfs_change_runs_timestamp_check
            gtfs_change_runs_progress_check
            gtfs_change_runs_organization_version_fkey
          ) do
        assert constraint in constraint_names(context.schema, "gtfs_change_runs")
      end
    end

    test "rejects invalid lifecycle, lease, timestamps, progress, and version scope", context do
      assert_constraint_violation(fn -> insert_run!(context, "not_a_state") end)
      assert_constraint_violation(fn -> insert_run!(context, "computing", lease: false) end)
      assert_constraint_violation(fn -> insert_run!(context, "review", lease: true) end)
      assert_constraint_violation(fn -> insert_run!(context, "completed", finished: false) end)
      assert_constraint_violation(fn -> insert_run!(context, "review", finished: true) end)
      assert_constraint_violation(fn -> insert_run!(context, "review", progress: {2, 1}) end)

      foreign_version = insert_version(context.schema, insert_organization(context.schema))

      assert_constraint_violation(fn ->
        insert_run!(%{context | version_id: foreign_version}, "pending_compute")
      end)
    end

    test "permits only one nonterminal run per organization/version but retains terminal history",
         context do
      insert_run!(context, "pending_compute")
      assert_constraint_violation(fn -> insert_run!(context, "review") end)

      terminal_context = %{context | version_id: Ecto.UUID.generate()}
      insert_version(context.schema, context.organization_id, terminal_context.version_id)
      insert_run!(terminal_context, "completed")
      insert_run!(terminal_context, "failed")
    end

    test "enforces unique decision IDs per run", context do
      run_id = insert_run!(context, "review")
      insert_decision!(context.schema, run_id, "stop:central")

      assert_constraint_violation(fn ->
        insert_decision!(context.schema, run_id, "stop:central")
      end)
    end
  end

  defp setup_prefix do
    schema = "test_change_runs_#{System.unique_integer([:positive])}"
    Ecto.Adapters.SQL.query!(Repo, ~s|CREATE SCHEMA "#{schema}"|, [])

    on_exit(fn ->
      Ecto.Adapters.SQL.query!(Repo, ~s|DROP SCHEMA IF EXISTS "#{schema}" CASCADE|, [])
    end)

    Ecto.Adapters.SQL.query!(
      Repo,
      """
      CREATE TABLE "#{schema}".organizations (
        id uuid PRIMARY KEY, name varchar(255) NOT NULL,
        inserted_at timestamp NOT NULL DEFAULT now(), updated_at timestamp NOT NULL DEFAULT now()
      )
      """,
      []
    )

    Ecto.Adapters.SQL.query!(
      Repo,
      """
      CREATE TABLE "#{schema}".gtfs_versions (
        id uuid PRIMARY KEY, organization_id uuid NOT NULL REFERENCES "#{schema}".organizations(id),
        name varchar(255) NOT NULL, inserted_at timestamp(6) NOT NULL, updated_at timestamp(6) NOT NULL
      )
      """,
      []
    )

    schema
  end

  defp insert_organization(schema) do
    id = Ecto.UUID.generate()

    Ecto.Adapters.SQL.query!(
      Repo,
      ~s|INSERT INTO "#{schema}".organizations (id, name) VALUES ($1, $2)|,
      [dump(id), "Test"]
    )

    id
  end

  defp insert_version(schema, organization_id, id \\ Ecto.UUID.generate()) do
    Ecto.Adapters.SQL.query!(
      Repo,
      """
      INSERT INTO "#{schema}".gtfs_versions (id, organization_id, name, inserted_at, updated_at)
      VALUES ($1, $2, $3, $4, $4)
      """,
      [dump(id), dump(organization_id), "Version", @now]
    )

    id
  end

  defp insert_run!(context, state, opts \\ []) do
    id = Ecto.UUID.generate()
    leased? = Keyword.get(opts, :lease, state in @lease_states)
    finished? = Keyword.get(opts, :finished, state in @terminal_states)
    {current, total} = Keyword.get(opts, :progress, {nil, nil})

    Ecto.Adapters.SQL.query!(
      Repo,
      """
      INSERT INTO "#{context.schema}".gtfs_change_runs (
        id, kind, state, progress_current, progress_total, summary, diagnostics, source_manifest,
        serializer_version, lease_generation, lease_token, lease_expires_at, started_at, finished_at,
        organization_id, gtfs_version_id, inserted_at, updated_at
      ) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14, $15, $16, $17, $17)
      """,
      [
        dump(id),
        "station_diff",
        state,
        current,
        total,
        "{}",
        [],
        "{}",
        1,
        0,
        if(leased?, do: dump(Ecto.UUID.generate())),
        if(leased?, do: @now),
        if(state == "pending_compute", do: nil, else: @now),
        if(finished?, do: @now),
        dump(context.organization_id),
        dump(context.version_id),
        @now
      ]
    )

    id
  end

  defp insert_decision!(schema, run_id, decision_id) do
    Ecto.Adapters.SQL.query!(
      Repo,
      """
      INSERT INTO "#{schema}".gtfs_change_decisions (
        id, change_run_id, decision_id, entity_type, action, status, natural_key,
        current_values, uploaded_values, changed_fields, dependency_keys, user_edited, inserted_at, updated_at
      ) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $13)
      """,
      [
        dump(Ecto.UUID.generate()),
        dump(run_id),
        decision_id,
        "stop",
        "modify",
        "pending",
        "central",
        "{}",
        "{}",
        [],
        [],
        false,
        @now
      ]
    )
  end

  defp migrate_up(schema),
    do: Ecto.Migrator.up(Repo, @migration_version, Migration, prefix: schema, log: false)

  defp assert_constraint_violation(fun), do: assert_raise(Postgrex.Error, fun)

  defp table_exists?(schema, table) do
    %{rows: rows} =
      Ecto.Adapters.SQL.query!(
        Repo,
        "SELECT 1 FROM information_schema.tables WHERE table_schema = $1 AND table_name = $2",
        [schema, table]
      )

    rows != []
  end

  defp index_exists?(schema, index) do
    %{rows: rows} =
      Ecto.Adapters.SQL.query!(
        Repo,
        "SELECT 1 FROM pg_indexes WHERE schemaname = $1 AND indexname = $2",
        [schema, index]
      )

    rows != []
  end

  defp constraint_names(schema, table) do
    %{rows: rows} =
      Ecto.Adapters.SQL.query!(
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
