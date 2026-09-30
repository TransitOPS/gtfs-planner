defmodule GtfsPlanner.Repo.Migrations.CreateAgentUsageCountersTest do
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL
  alias Ecto.Adapters.SQL.Sandbox
  alias Ecto.Migrator
  alias GtfsPlanner.Repo

  @migration_glob "../../../../priv/repo/migrations/*_create_agent_usage_counters.exs"

  @migration_path (
                    matches = Path.wildcard(Path.expand(@migration_glob, __DIR__))

                    case matches do
                      [path] ->
                        path

                      other ->
                        raise "expected exactly one agent-usage-counters migration, got: #{inspect(other)}"
                    end
                  )

  Code.require_file(@migration_path)

  @migration_version @migration_path
                     |> Path.basename()
                     |> String.split("_", parts: 2)
                     |> hd()
                     |> String.to_integer()

  alias GtfsPlanner.Repo.Migrations.CreateAgentUsageCounters, as: Migration

  @day ~D[2026-09-30]
  @now ~U[2026-09-30 00:00:00.000000Z]

  setup_all do
    Sandbox.mode(Repo, :auto)

    on_exit(fn ->
      Sandbox.mode(Repo, :manual)
    end)

    :ok
  end

  test "creates the daily counter table and unique organization scope index" do
    schema = setup_prefix()
    migrate_up(schema)

    assert table_exists?(schema, "agent_usage_counters")
    assert index_exists?(schema, "agent_usage_counters_org_scope_day_index")
    assert "agent_usage_counters_attempts_check" in check_constraint_names(schema)
  end

  test "duplicate organization scope and day rows violate the unique index" do
    schema = setup_prefix()
    org_id = insert_org(schema)
    migrate_up(schema)

    insert_counter(schema, org_id, "organization")

    error =
      assert_raise Postgrex.Error, fn ->
        insert_counter(schema, org_id, "organization")
      end

    assert error.postgres.code == :unique_violation
  end

  test "negative attempt counts violate the database check" do
    schema = setup_prefix()
    org_id = insert_org(schema)
    migrate_up(schema)

    error =
      assert_raise Postgrex.Error, fn ->
        insert_counter(schema, org_id, Ecto.UUID.generate(), attempts: -1)
      end

    assert error.postgres.code == :check_violation
  end

  test "deleting an organization cascades to its daily counters" do
    schema = setup_prefix()
    org_id = insert_org(schema)
    migrate_up(schema)
    insert_counter(schema, org_id, "organization")

    SQL.query!(Repo, ~s|DELETE FROM "#{schema}".organizations WHERE id = $1|, [dump(org_id)])

    assert %{rows: [[0]]} =
             SQL.query!(
               Repo,
               ~s|SELECT count(*) FROM "#{schema}".agent_usage_counters WHERE organization_id = $1|,
               [dump(org_id)]
             )
  end

  defp setup_prefix do
    schema = "test_agent_usage_counters_#{System.unique_integer([:positive])}"
    SQL.query!(Repo, ~s|CREATE SCHEMA "#{schema}"|, [])

    on_exit(fn ->
      SQL.query!(Repo, ~s|DROP SCHEMA IF EXISTS "#{schema}" CASCADE|, [])
    end)

    SQL.query!(
      Repo,
      """
      CREATE TABLE "#{schema}".organizations (
        id uuid PRIMARY KEY,
        inserted_at timestamp(6) NOT NULL DEFAULT now(),
        updated_at timestamp(6) NOT NULL DEFAULT now()
      )
      """,
      []
    )

    schema
  end

  defp insert_org(schema) do
    id = Ecto.UUID.generate()

    SQL.query!(Repo, ~s|INSERT INTO "#{schema}".organizations (id) VALUES ($1)|, [dump(id)])

    id
  end

  defp insert_counter(schema, org_id, scope_key, opts \\ []) do
    id = Ecto.UUID.generate()
    attempts = Keyword.get(opts, :attempts, 0)

    SQL.query!(
      Repo,
      """
      INSERT INTO "#{schema}".agent_usage_counters (
        id, organization_id, scope_key, day, attempts, inserted_at, updated_at
      ) VALUES ($1, $2, $3, $4, $5, $6, $6)
      """,
      [dump(id), dump(org_id), scope_key, @day, attempts, @now]
    )
  end

  defp migrate_up(schema),
    do: Migrator.up(Repo, @migration_version, Migration, prefix: schema, log: false)

  defp table_exists?(schema, table) do
    %{rows: rows} =
      SQL.query!(
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
      SQL.query!(
        Repo,
        """
        SELECT 1 FROM pg_indexes
        WHERE schemaname = $1 AND indexname = $2
        """,
        [schema, index_name]
      )

    rows != []
  end

  defp check_constraint_names(schema) do
    %{rows: rows} =
      SQL.query!(
        Repo,
        """
        SELECT con.conname
        FROM pg_constraint con
        JOIN pg_class rel ON rel.oid = con.conrelid
        JOIN pg_namespace nsp ON nsp.oid = rel.relnamespace
        WHERE nsp.nspname = $1
          AND rel.relname = 'agent_usage_counters'
          AND con.contype = 'c'
        """,
        [schema]
      )

    List.flatten(rows)
  end

  defp dump(uuid), do: Ecto.UUID.dump!(uuid)
end
