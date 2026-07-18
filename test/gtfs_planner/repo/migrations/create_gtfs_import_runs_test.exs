defmodule GtfsPlanner.Repo.Migrations.CreateGtfsImportRunsTest do
  # This migration test exercises real DDL (table, check constraints, indexes,
  # rollback) plus the `Ecto.Migrator`, which runs the migration in a separate
  # task process. That cannot share the DataCase SQL sandbox transaction, so we
  # run against real autocommit connections in `:auto` mode and isolate all
  # writes in a unique PostgreSQL schema that is dropped on exit. The global
  # sandbox mode is restored afterwards.
  use ExUnit.Case, async: false

  alias GtfsPlanner.Repo

  setup_all do
    Ecto.Adapters.SQL.Sandbox.mode(Repo, :auto)

    on_exit(fn ->
      Ecto.Adapters.SQL.Sandbox.mode(Repo, :manual)
    end)

    :ok
  end

  @migration_glob "../../../../priv/repo/migrations/*_create_gtfs_import_runs.exs"

  @migration_path (
                     matches = Path.wildcard(Path.expand(@migration_glob, __DIR__))

                     case matches do
                       [path] -> path
                       other -> raise "expected exactly one import-runs migration file, got: #{inspect(other)}"
                     end
                   )

  Code.require_file(@migration_path)

  @migration_version @migration_path
                     |> Path.basename()
                     |> String.split("_", parts: 2)
                     |> hd()
                     |> String.to_integer()

  alias GtfsPlanner.Repo.Migrations.CreateGtfsImportRuns, as: Migration

  alias GtfsPlanner.Gtfs.Import.Run

  # States that require an active lease + finished_at absence.
  @lease_states ~w(pending running cleaning)
  # Terminal import outcomes that require finished_at.
  @terminal_states ~w(failed partial interrupted publication_failed published cleaned cleanup_failed)
  # Cleanup states that require cleanup_started_at.
  @cleanup_states ~w(cleaning cleanup_failed cleaned)

  @now ~U[2026-01-01 00:00:00.000000Z]

  describe "up/0 adds the run table with indexes and constraints" do
    test "the table, unique index, composite index, and check constraints exist" do
      schema = setup_prefix()
      migrate_up(schema)

      assert table_exists?(schema, "gtfs_import_runs")
      assert index_exists?(schema, "gtfs_import_runs_gtfs_version_id_index")
      assert index_exists?(schema, "gtfs_import_runs_org_state_updated_at_index")

      names = check_constraint_names(schema, "gtfs_import_runs")

      for expected <-
            ~w(gtfs_import_runs_state_check gtfs_import_runs_lease_check gtfs_import_runs_finished_at_check gtfs_import_runs_cleanup_started_at_check gtfs_import_runs_cleanup_finished_at_check gtfs_import_runs_failed_row_check) do
        assert expected in names, "expected check constraint #{expected} to exist, got #{inspect(names)}"
      end
    end
  end

  describe "up/0 accepts the valid state/lease/timestamp matrix" do
    setup do
      schema = setup_prefix()
      org_id = insert_org(schema)
      migrate_up(schema)
      %{schema: schema, org_id: org_id}
    end

    test "every valid state with its correct lease/timestamp pairing is accepted", %{
      schema: schema,
      org_id: org_id
    } do
      for state <- Run.states() do
        assert :ok = insert_run(schema, org_id, state)
      end
    end

    test "a running/pending/cleaning run with both lease fields is accepted", %{
      schema: schema,
      org_id: org_id
    } do
      for state <- @lease_states do
        assert :ok = insert_run(schema, org_id, state, lease: true)
      end
    end
  end

  describe "up/0 rejects invalid lease pairings" do
    setup do
      schema = setup_prefix()
      org_id = insert_org(schema)
      migrate_up(schema)
      %{schema: schema, org_id: org_id}
    end

    test "running/pending/cleaning without both lease fields raises", %{schema: schema, org_id: org_id} do
      for state <- @lease_states do
        assert_constraint_violation(fn -> insert_run!(schema, org_id, state, lease: false) end)
      end
    end

    test "any non-active/terminal state with a non-nil lease is rejected", %{
      schema: schema,
      org_id: org_id
    } do
      for state <- @terminal_states do
        assert_constraint_violation(fn -> insert_run!(schema, org_id, state, lease: true) end)
      end
    end
  end

  describe "up/0 rejects invalid timestamp pairings" do
    setup do
      schema = setup_prefix()
      org_id = insert_org(schema)
      migrate_up(schema)
      %{schema: schema, org_id: org_id}
    end

    test "a terminal import state without finished_at is rejected", %{schema: schema, org_id: org_id} do
      for state <- @terminal_states do
        assert_constraint_violation(fn -> insert_run!(schema, org_id, state, finished: false) end)
      end
    end

    test "cleanup states require cleanup_started_at", %{schema: schema, org_id: org_id} do
      for state <- @cleanup_states do
        assert_constraint_violation(fn ->
          insert_run!(schema, org_id, state, cleanup_started: false)
        end)
      end
    end

    test "only cleaned may carry cleanup_finished_at", %{schema: schema, org_id: org_id} do
      for state <- Run.states() -- ["cleaned"] do
        assert_constraint_violation(fn ->
          insert_run!(schema, org_id, state, cleanup_finished: true)
        end)
      end
    end

    test "non-cleanup states must not carry cleanup_started_at", %{schema: schema, org_id: org_id} do
      for state <- Run.states() -- @cleanup_states do
        assert_constraint_violation(fn ->
          insert_run!(schema, org_id, state, cleanup_started: true)
        end)
      end
    end
  end

  describe "up/0 old-release compatibility" do
    test "a raw insert with only pre-migration gtfs_versions columns still succeeds for the versions table",
         %{} do
      schema = setup_prefix()
      org_id = insert_org(schema)
      migrate_up(schema)

      id = Ecto.UUID.generate()

      Ecto.Adapters.SQL.query!(
        Repo,
        """
        INSERT INTO "#{schema}".gtfs_versions
          (id, organization_id, name, inserted_at, updated_at)
        VALUES ($1, $2, $3, $4, $4)
        """,
        [dump(id), dump(org_id), "Old Release", @now]
      )

      assert [%{name: "Old Release"}] = pre_migration_versions(schema)
    end
  end

  describe "down/0 rollback" do
    test "removes the table, indexes, and constraints but leaves gtfs_versions unchanged" do
      schema = setup_prefix()
      org_id = insert_org(schema)
      id = Ecto.UUID.generate()

      Ecto.Adapters.SQL.query!(
        Repo,
        """
        INSERT INTO "#{schema}".gtfs_versions
          (id, organization_id, name, inserted_at, updated_at)
        VALUES ($1, $2, $3, $4, $4)
        """,
        [dump(id), dump(org_id), "Published", @now]
      )

      migrate_up(schema)

      assert table_exists?(schema, "gtfs_import_runs")
      assert check_constraint_names(schema, "gtfs_import_runs") != []

      migrate_down(schema)

      refute table_exists?(schema, "gtfs_import_runs")
      assert pre_migration_versions(schema) == [%{name: "Published"}]
    end
  end

  # --- helpers -------------------------------------------------------------

  defp setup_prefix do
    schema = "test_import_runs_#{System.unique_integer([:positive])}"

    Ecto.Adapters.SQL.query!(Repo, ~s|CREATE SCHEMA "#{schema}"|, [])

    on_exit(fn ->
      Ecto.Adapters.SQL.query!(
        GtfsPlanner.Repo,
        ~s|DROP SCHEMA IF EXISTS "#{schema}" CASCADE|,
        []
      )
    end)

    Ecto.Adapters.SQL.query!(
      Repo,
      """
      CREATE TABLE "#{schema}".organizations (
        id uuid PRIMARY KEY,
        name varchar(255) NOT NULL,
        inserted_at timestamp NOT NULL DEFAULT now(),
        updated_at timestamp NOT NULL DEFAULT now()
      )
      """,
      []
    )

    Ecto.Adapters.SQL.query!(
      Repo,
      """
      CREATE TABLE "#{schema}".gtfs_versions (
        id uuid PRIMARY KEY,
        organization_id uuid NOT NULL REFERENCES "#{schema}".organizations(id),
        name varchar(255) NOT NULL DEFAULT 'First Version',
        inserted_at timestamp(6) NOT NULL,
        updated_at timestamp(6) NOT NULL
      )
      """,
      []
    )

    schema
  end

  defp insert_org(schema) do
    id = Ecto.UUID.generate()

    Ecto.Adapters.SQL.query!(
      Repo,
      ~s|INSERT INTO "#{schema}".organizations (id, name) VALUES ($1, $2)|,
      [dump(id), "Org #{System.unique_integer([:positive])}"]
    )

    id
  end

  # Builds a run row that satisfies the constraints for the given state unless a
  # specific defect is requested via the options.
  defp insert_run(schema, org_id, state, opts \\ []) do
    insert_run!(schema, org_id, state, opts)
    :ok
  rescue
    _ -> :error
  end

  defp insert_run!(schema, org_id, state, opts \\ []) do
    lease = Keyword.get(opts, :lease, state in @lease_states)
    finished = Keyword.get(opts, :finished, state in @terminal_states)
    cleanup_started = Keyword.get(opts, :cleanup_started, state in @cleanup_states)
    cleanup_finished = Keyword.get(opts, :cleanup_finished, state == "cleaned")
    failed_row = Keyword.get(opts, :failed_row, nil)

    id = Ecto.UUID.generate()
    version_id = Ecto.UUID.generate()

    lease_token = if lease, do: dump(Ecto.UUID.generate()), else: nil
    lease_expires_at = if lease, do: @now, else: nil
    finished_at = if finished, do: @now, else: nil
    cleanup_started_at = if cleanup_started, do: @now, else: nil
    cleanup_finished_at = if cleanup_finished, do: @now, else: nil

    Ecto.Adapters.SQL.query!(
      Repo,
      """
      INSERT INTO "#{schema}".gtfs_import_runs (
        id, organization_id, gtfs_version_id, version_name, state,
        committed_counts, counts_complete,
        failed_row,
        lease_token, lease_expires_at,
        finished_at, cleanup_started_at, cleanup_finished_at,
        inserted_at, updated_at
      ) VALUES (
        $1, $2, $3, $4, $5,
        $6, $7,
        $8,
        $9, $10,
        $11, $12, $13,
        $14, $14
      )
      """,
      [
        dump(id),
        dump(org_id),
        dump(version_id),
        "Version #{System.unique_integer([:positive])}",
        state,
        "{}",
        false,
        failed_row,
        lease_token,
        lease_expires_at,
        finished_at,
        cleanup_started_at,
        cleanup_finished_at,
        @now
      ]
    )
  end

  # Each statement runs in its own autocommit transaction, so a rejected INSERT
  # fails only itself and later assertions keep working.
  defp assert_constraint_violation(fun) do
    assert_raise Postgrex.Error, fun
  end

  defp migrate_up(schema) do
    Ecto.Migrator.up(Repo, @migration_version, Migration, prefix: schema, log: false)
  end

  defp migrate_down(schema) do
    Ecto.Migrator.down(Repo, @migration_version, Migration, prefix: schema, log: false)
  end

  defp table_exists?(schema, table) do
    %{rows: rows} =
      Ecto.Adapters.SQL.query!(
        Repo,
        """
        SELECT 1 FROM information_schema.tables
        WHERE table_schema = $1 AND table_name = $2
        """,
        [schema, table]
      )

    rows != []
  end

  defp index_exists?(schema, index_name) do
    %{rows: rows} =
      Ecto.Adapters.SQL.query!(
        Repo,
        """
        SELECT indexname FROM pg_indexes
        WHERE schemaname = $1 AND tablename = 'gtfs_import_runs' AND indexname = $2
        """,
        [schema, index_name]
      )

    rows != []
  end

  defp check_constraint_names(schema, table) do
    %{rows: rows} =
      Ecto.Adapters.SQL.query!(
        Repo,
        """
        SELECT con.conname
        FROM pg_constraint con
        JOIN pg_class rel ON rel.oid = con.conrelid
        JOIN pg_namespace nsp ON nsp.oid = rel.relnamespace
        WHERE nsp.nspname = $1 AND rel.relname = $2 AND con.contype = 'c'
        """,
        [schema, table]
      )

    List.flatten(rows)
  end

  defp pre_migration_versions(schema) do
    %{rows: rows} =
      Ecto.Adapters.SQL.query!(
        Repo,
        ~s|SELECT name FROM "#{schema}".gtfs_versions ORDER BY name|,
        []
      )

    Enum.map(rows, fn [name] -> %{name: name} end)
  end

  defp dump(uuid), do: Ecto.UUID.dump!(uuid)
end
