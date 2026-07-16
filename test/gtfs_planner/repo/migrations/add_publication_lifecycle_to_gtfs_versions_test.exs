defmodule GtfsPlanner.Repo.Migrations.AddPublicationLifecycleToGtfsVersionsTest do
  # This migration test exercises real DDL (add columns, defaults, check
  # constraints, index, rollback) plus the `Ecto.Migrator`, which runs the
  # migration in a separate task process. That cannot share the DataCase SQL
  # sandbox transaction, so we run against real autocommit connections in
  # `:auto` mode and isolate all writes in a unique PostgreSQL schema that is
  # dropped on exit. The global sandbox mode is restored afterwards.
  use ExUnit.Case, async: false

  alias GtfsPlanner.Repo

  setup_all do
    Ecto.Adapters.SQL.Sandbox.mode(Repo, :auto)

    on_exit(fn ->
      Ecto.Adapters.SQL.Sandbox.mode(Repo, :manual)
    end)

    :ok
  end

  @migration_glob "../../../../priv/repo/migrations/*_add_publication_lifecycle_to_gtfs_versions.exs"

  # Resolve the single generated migration file rather than hard-coding a
  # timestamp, then load it so its module becomes available.
  @migration_path (
                     matches =
                       Path.wildcard(Path.expand(@migration_glob, __DIR__))

                     case matches do
                       [path] ->
                         path

                       other ->
                         raise "expected exactly one lifecycle migration file, got: #{inspect(other)}"
                     end
                   )

  Code.require_file(@migration_path)

  @migration_version @migration_path
                     |> Path.basename()
                     |> String.split("_", parts: 2)
                     |> hd()
                     |> String.to_integer()

  alias GtfsPlanner.Repo.Migrations.AddPublicationLifecycleToGtfsVersions, as: Migration

  @valid_states ~w(staging importing published failed)

  describe "up/0 backfill" do
    test "backfills each existing version to published with published_at equal to inserted_at" do
      schema = setup_prefix()

      id_a = Ecto.UUID.generate()
      id_b = Ecto.UUID.generate()
      org_id = insert_org(schema)
      insert_pre_migration_version(schema, id_a, org_id, "Alpha", ~U[2026-01-01 00:00:00.000000Z])
      insert_pre_migration_version(schema, id_b, org_id, "Beta", ~U[2026-02-01 00:00:00.000000Z])

      migrate_up(schema)

      rows = lifecycle_rows(schema)

      assert Enum.count(rows) == 2

      for %{status: status, published_at: published_at, inserted_at: inserted_at} <- rows do
        assert status == "published"
        assert published_at == inserted_at
      end
    end
  end

  describe "up/0 old-release compatibility" do
    test "an old-shape insert omitting both lifecycle columns receives a paired published default" do
      schema = setup_prefix()
      org_id = insert_org(schema)
      migrate_up(schema)

      id = Ecto.UUID.generate()

      # An old release only knows the pre-migration columns and supplies exactly
      # them, omitting both lifecycle columns.
      Ecto.Adapters.SQL.query!(
        Repo,
        """
        INSERT INTO "#{schema}".gtfs_versions
          (id, organization_id, name, inserted_at, updated_at)
        VALUES ($1, $2, $3, $4, $4)
        """,
        [dump(id), dump(org_id), "Old Release", ~U[2026-03-01 00:00:00.000000Z]]
      )

      [row] = lifecycle_rows(schema)

      assert row.status == "published"
      assert row.published_at != nil
    end
  end

  describe "up/0 check constraints" do
    setup do
      schema = setup_prefix()
      org_id = insert_org(schema)
      migrate_up(schema)
      %{schema: schema, org_id: org_id}
    end

    test "accepts every valid state/timestamp pair", %{schema: schema, org_id: org_id} do
      for status <- @valid_states do
        published_at =
          if status == "published", do: ~U[2026-04-01 00:00:00.000000Z], else: nil

        assert :ok = insert_lifecycle_version(schema, org_id, status, published_at)
      end
    end

    test "rejects published without published_at", %{schema: schema, org_id: org_id} do
      assert_constraint_violation(fn ->
        insert_lifecycle_version!(schema, org_id, "published", nil)
      end)
    end

    test "rejects non-published states carrying a published_at", %{schema: schema, org_id: org_id} do
      for status <- ~w(staging importing failed) do
        assert_constraint_violation(fn ->
          insert_lifecycle_version!(schema, org_id, status, ~U[2026-04-01 00:00:00.000000Z])
        end)
      end
    end

    test "rejects an unknown status value", %{schema: schema, org_id: org_id} do
      assert_constraint_violation(fn ->
        insert_lifecycle_version!(schema, org_id, "bogus", nil)
      end)
    end
  end

  describe "down/0 rollback" do
    test "removes the lifecycle columns, constraints, and index" do
      schema = setup_prefix()
      _org_id = insert_org(schema)
      migrate_up(schema)

      assert lifecycle_columns(schema) == ["published_at", "publication_status"] |> Enum.sort()
      assert lifecycle_check_constraints(schema) != []
      assert lifecycle_index_exists?(schema)

      migrate_down(schema)

      assert lifecycle_columns(schema) == []
      assert lifecycle_check_constraints(schema) == []
      refute lifecycle_index_exists?(schema)
    end
  end

  # --- helpers -------------------------------------------------------------

  defp setup_prefix do
    schema = "test_lifecycle_#{System.unique_integer([:positive])}"

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

  defp insert_pre_migration_version(schema, id, org_id, name, ts) do
    Ecto.Adapters.SQL.query!(
      Repo,
      """
      INSERT INTO "#{schema}".gtfs_versions (id, organization_id, name, inserted_at, updated_at)
      VALUES ($1, $2, $3, $4, $4)
      """,
      [dump(id), dump(org_id), name, ts]
    )
  end

  defp insert_lifecycle_version!(schema, org_id, status, published_at) do
    id = Ecto.UUID.generate()

    Ecto.Adapters.SQL.query!(
      Repo,
      """
      INSERT INTO "#{schema}".gtfs_versions
        (id, organization_id, name, publication_status, published_at, inserted_at, updated_at)
      VALUES ($1, $2, $3, $4, $5, now(), now())
      """,
      [dump(id), dump(org_id), "V #{System.unique_integer([:positive])}", status, published_at]
    )
  end

  defp insert_lifecycle_version(schema, org_id, status, published_at) do
    insert_lifecycle_version!(schema, org_id, status, published_at)
    :ok
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

  defp lifecycle_rows(schema) do
    %{rows: rows} =
      Ecto.Adapters.SQL.query!(
        Repo,
        ~s|SELECT publication_status, published_at, inserted_at FROM "#{schema}".gtfs_versions|,
        []
      )

    Enum.map(rows, fn [status, published_at, inserted_at] ->
      %{status: status, published_at: published_at, inserted_at: inserted_at}
    end)
  end

  defp lifecycle_columns(schema) do
    %{rows: rows} =
      Ecto.Adapters.SQL.query!(
        Repo,
        """
        SELECT column_name FROM information_schema.columns
        WHERE table_schema = $1 AND table_name = 'gtfs_versions'
          AND column_name IN ('publication_status', 'published_at')
        """,
        [schema]
      )

    rows |> List.flatten() |> Enum.sort()
  end

  defp lifecycle_check_constraints(schema) do
    %{rows: rows} =
      Ecto.Adapters.SQL.query!(
        Repo,
        """
        SELECT con.conname
        FROM pg_constraint con
        JOIN pg_class rel ON rel.oid = con.conrelid
        JOIN pg_namespace nsp ON nsp.oid = rel.relnamespace
        WHERE nsp.nspname = $1 AND rel.relname = 'gtfs_versions' AND con.contype = 'c'
        """,
        [schema]
      )

    List.flatten(rows)
  end

  defp lifecycle_index_exists?(schema) do
    %{rows: rows} =
      Ecto.Adapters.SQL.query!(
        Repo,
        """
        SELECT indexname FROM pg_indexes
        WHERE schemaname = $1 AND tablename = 'gtfs_versions'
          AND indexname = 'gtfs_versions_org_status_published_at_index'
        """,
        [schema]
      )

    rows != []
  end

  defp dump(uuid), do: Ecto.UUID.dump!(uuid)
end
