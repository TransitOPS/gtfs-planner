defmodule GtfsPlanner.Repo.Migrations.DropApiKeysTest do
  # This migration test exercises real DDL (drop/recreate table, FK, defaults)
  # plus the `Ecto.Migrator`, which runs the migration in a separate task
  # process. That cannot share the DataCase SQL sandbox transaction, so we run
  # against real autocommit connections in `:auto` mode and isolate all writes
  # in a unique PostgreSQL schema that is dropped on exit. The global sandbox
  # mode is restored afterwards. The main test schema is never modified.
  use ExUnit.Case, async: false

  alias GtfsPlanner.Repo

  setup_all do
    Ecto.Adapters.SQL.Sandbox.mode(Repo, :auto)

    on_exit(fn ->
      Ecto.Adapters.SQL.Sandbox.mode(Repo, :manual)
    end)

    :ok
  end

  @migration_glob "../../../../priv/repo/migrations/*_drop_api_keys.exs"

  @migration_path (
                    matches = Path.wildcard(Path.expand(@migration_glob, __DIR__))

                    case matches do
                      [path] ->
                        path

                      other ->
                        raise "expected exactly one drop_api_keys migration file, got: #{inspect(other)}"
                    end
                  )

  Code.require_file(@migration_path)

  @migration_version @migration_path
                     |> Path.basename()
                     |> String.split("_", parts: 2)
                     |> hd()
                     |> String.to_integer()

  alias GtfsPlanner.Repo.Migrations.DropApiKeys, as: Migration

  @create_migration_path Path.expand(
                           "../../../../priv/repo/migrations/20251223034107_create_api_keys.exs",
                           __DIR__
                         )

  @create_migration_digest (
                             @create_migration_path
                             |> File.read!()
                             |> then(&:crypto.hash(:sha256, &1))
                             |> Base.encode16(case: :lower)
                           )

  describe "up/0 drops api_keys in an isolated prefix" do
    test "removes api_keys and leaves the main public schema untouched" do
      schema = setup_prefix()
      assert table_exists?(schema, "api_keys")
      public_existed_before? = table_exists?("public", "api_keys")

      migrate_up(schema)

      refute table_exists?(schema, "api_keys")
      assert table_exists?("public", "api_keys") == public_existed_before?
    end
  end

  describe "down/0 recreates the historical structure" do
    test "restores columns, PK, cascading org FK, defaults, and utc microsecond timestamps" do
      schema = setup_prefix()
      migrate_up(schema)
      refute table_exists?(schema, "api_keys")

      migrate_down(schema)

      assert table_exists?(schema, "api_keys")
      assert_api_keys_structure(schema)
    end
  end

  describe "up/down/up lifecycle" do
    test "a second up removes the recreated relation without error" do
      schema = setup_prefix()

      migrate_up(schema)
      refute table_exists?(schema, "api_keys")

      migrate_down(schema)
      assert table_exists?(schema, "api_keys")
      assert_api_keys_structure(schema)

      migrate_up(schema)
      refute table_exists?(schema, "api_keys")
    end
  end

  describe "historical create migration and release checkpoint" do
    test "the historical create migration is unchanged" do
      assert File.exists?(@create_migration_path)

      source = File.read!(@create_migration_path)

      assert source =~ "defmodule GtfsPlanner.Repo.Migrations.CreateApiKeys"
      assert source =~ "create table(:api_keys, primary_key: false)"
      assert source =~ "add :id, :binary_id, primary_key: true"
      assert source =~ "references(:organizations, on_delete: :delete_all, type: :binary_id)"
      assert source =~ "add :description, :string, null: false"
      assert source =~ ~s|add :roles, {:array, :string}, default: "{}"|
      assert source =~ "add :version, :integer, default: 1"
      assert source =~ "add :secret_hash, :binary, null: false"
      assert source =~ "timestamps(type: :utc_datetime_usec)"

      # Pin the file contents so any edit to the historical create migration fails.
      assert @create_migration_digest ==
               (:crypto.hash(:sha256, source) |> Base.encode16(case: :lower))
    end

    test "migration module documents empty-structure rollback and release drainage" do
      source = File.read!(@migration_path)

      assert source =~ "Release checkpoint"
      assert source =~ ~r/drain/i
      assert source =~ ~r/backup/i
      assert source =~ "GtfsPlanner.Release.migrate"
      assert source =~ "empty"
      assert source =~ ~r/credential/i
      assert source =~ "down/0"
      refute source =~ "def change"
    end
  end

  # --- helpers -------------------------------------------------------------

  defp setup_prefix do
    schema = "test_drop_api_keys_#{System.unique_integer([:positive])}"

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

    # Original api_keys shape from 20251223034107_create_api_keys.exs
    Ecto.Adapters.SQL.query!(
      Repo,
      """
      CREATE TABLE "#{schema}".api_keys (
        id uuid PRIMARY KEY,
        organization_id uuid NOT NULL REFERENCES "#{schema}".organizations(id) ON DELETE CASCADE,
        description varchar(255) NOT NULL,
        roles character varying[] DEFAULT '{}',
        version integer DEFAULT 1,
        secret_hash bytea NOT NULL,
        inserted_at timestamp(6) NOT NULL,
        updated_at timestamp(6) NOT NULL
      )
      """,
      []
    )

    schema
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

  defp assert_api_keys_structure(schema) do
    columns = column_catalog(schema)

    assert_column(columns, "id", udt: "uuid", nullable?: false)
    assert_column(columns, "organization_id", udt: "uuid", nullable?: false)
    assert_column(columns, "description", udt: "varchar", nullable?: false)
    assert_column(columns, "secret_hash", udt: "bytea", nullable?: false)

    roles = Map.fetch!(columns, "roles")
    assert roles.udt_name == "_varchar"
    # Historical create used default without null: false; match that shape.
    assert roles_default?(roles.column_default),
           "unexpected roles default: #{inspect(roles.column_default)}"

    version = Map.fetch!(columns, "version")
    assert version.udt_name == "int4"
    assert version_default?(version.column_default),
           "unexpected version default: #{inspect(version.column_default)}"

    for ts <- ["inserted_at", "updated_at"] do
      col = Map.fetch!(columns, ts)
      assert col.udt_name == "timestamp"
      assert col.datetime_precision == 6
      assert col.is_nullable == "NO"
    end

    assert primary_key_columns(schema) == ["id"]

    fk = organization_foreign_key(schema)
    assert fk.foreign_table_name == "organizations"
    assert fk.foreign_column_name == "id"
    assert fk.delete_rule == "CASCADE"
    assert fk.column_name == "organization_id"
  end

  defp column_catalog(schema) do
    %{rows: rows} =
      Ecto.Adapters.SQL.query!(
        Repo,
        """
        SELECT column_name, udt_name, is_nullable, column_default, datetime_precision
        FROM information_schema.columns
        WHERE table_schema = $1 AND table_name = 'api_keys'
        """,
        [schema]
      )

    Map.new(rows, fn [name, udt, nullable, default, precision] ->
      {name,
       %{
         udt_name: udt,
         is_nullable: nullable,
         column_default: default,
         datetime_precision: precision
       }}
    end)
  end

  defp assert_column(columns, name, opts) do
    col = Map.fetch!(columns, name)
    assert col.udt_name == Keyword.fetch!(opts, :udt)
    expected_nullable = if Keyword.fetch!(opts, :nullable?), do: "YES", else: "NO"
    assert col.is_nullable == expected_nullable
  end

  defp roles_default?(default) when is_binary(default) do
    default in [
      "'{}'::character varying[]",
      "'{}'::varchar[]",
      "ARRAY[]::character varying[]",
      "ARRAY[]::varchar[]"
    ] or String.contains?(default, "{}")
  end

  defp roles_default?(_), do: false

  defp version_default?(default) when is_binary(default) do
    default in ["1", "1::integer", "(1)::integer"] or String.starts_with?(default, "1")
  end

  defp version_default?(_), do: false

  defp primary_key_columns(schema) do
    %{rows: rows} =
      Ecto.Adapters.SQL.query!(
        Repo,
        """
        SELECT a.attname
        FROM pg_index i
        JOIN pg_class c ON c.oid = i.indrelid
        JOIN pg_namespace n ON n.oid = c.relnamespace
        JOIN pg_attribute a ON a.attrelid = c.oid AND a.attnum = ANY(i.indkey)
        WHERE n.nspname = $1
          AND c.relname = 'api_keys'
          AND i.indisprimary
        ORDER BY a.attnum
        """,
        [schema]
      )

    List.flatten(rows)
  end

  defp organization_foreign_key(schema) do
    %{rows: rows} =
      Ecto.Adapters.SQL.query!(
        Repo,
        """
        SELECT
          kcu.column_name,
          ccu.table_name AS foreign_table_name,
          ccu.column_name AS foreign_column_name,
          rc.delete_rule
        FROM information_schema.table_constraints tc
        JOIN information_schema.key_column_usage kcu
          ON tc.constraint_name = kcu.constraint_name
          AND tc.table_schema = kcu.table_schema
        JOIN information_schema.constraint_column_usage ccu
          ON ccu.constraint_name = tc.constraint_name
          AND ccu.table_schema = tc.table_schema
        JOIN information_schema.referential_constraints rc
          ON rc.constraint_name = tc.constraint_name
          AND rc.constraint_schema = tc.table_schema
        WHERE tc.table_schema = $1
          AND tc.table_name = 'api_keys'
          AND tc.constraint_type = 'FOREIGN KEY'
        """,
        [schema]
      )

    case rows do
      [[column_name, foreign_table_name, foreign_column_name, delete_rule]] ->
        %{
          column_name: column_name,
          foreign_table_name: foreign_table_name,
          foreign_column_name: foreign_column_name,
          delete_rule: delete_rule
        }

      other ->
        flunk("expected one organization FK, got: #{inspect(other)}")
    end
  end
end
