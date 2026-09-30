defmodule GtfsPlanner.Gtfs.Rosters.AddBasicRostersMigrationTest do
  # The roster migration is exercised against real DDL in a unique disposable
  # PostgreSQL schema dropped on exit, so no retained development database is
  # ever rolled back.
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL
  alias Ecto.Adapters.SQL.Sandbox
  alias GtfsPlanner.Repo

  setup_all do
    Sandbox.mode(Repo, :auto)

    on_exit(fn ->
      Sandbox.mode(Repo, :manual)
    end)

    :ok
  end

  @migration_glob "../../../../priv/repo/migrations/*_add_basic_rosters.exs"

  @migration_path (
                    matches = Path.wildcard(Path.expand(@migration_glob, __DIR__))

                    case matches do
                      [path] ->
                        path

                      other ->
                        raise "expected exactly one add_basic_rosters migration file, got: #{inspect(other)}"
                    end
                  )

  Code.require_file(@migration_path)

  @migration_version @migration_path
                     |> Path.basename()
                     |> String.split("_", parts: 2)
                     |> hd()
                     |> String.to_integer()

  alias GtfsPlanner.Repo.Migrations.AddBasicRosters, as: Migration

  @now ~U[2026-09-30 00:00:00.000000Z]

  describe "up/0 creates the roster tables, their indexes and the roster settings columns" do
    test "the three tables exist with every index named in the spec contracts" do
      schema = setup_prefix()
      migrate_up(schema)

      assert table_exists?(schema, "operators")
      assert table_exists?(schema, "roster_lines")
      assert table_exists?(schema, "roster_line_days")

      assert index_names(schema, "operators") == [
               "operators_organization_id_employee_id_index",
               "operators_pkey"
             ]

      assert "roster_lines_organization_id_gtfs_version_id_line_number_index" in index_names(
               schema,
               "roster_lines"
             )

      assert "roster_lines_one_line_per_operator" in index_names(schema, "roster_lines")
      assert "roster_lines_operator_id_index" in index_names(schema, "roster_lines")

      assert "roster_line_days_roster_line_id_weekday_index" in index_names(
               schema,
               "roster_line_days"
             )

      assert "roster_line_days_run_once_per_weekday" in index_names(schema, "roster_line_days")

      by_name =
        schema
        |> table_index_defs("roster_line_days")
        |> Map.new(&{&1["indexname"], &1["indexdef"]})

      assert by_name["roster_line_days_run_once_per_weekday"] =~ "UNIQUE"
      assert by_name["roster_line_days_run_once_per_weekday"] =~ "weekday"
      assert by_name["roster_line_days_run_once_per_weekday"] =~ "day_type_key"
      assert by_name["roster_line_days_run_once_per_weekday"] =~ "run_id"

      operator_index =
        schema
        |> table_index_defs("roster_lines")
        |> Map.new(&{&1["indexname"], &1["indexdef"]})
        |> Map.fetch!("roster_lines_one_line_per_operator")

      assert operator_index =~ "UNIQUE"
      assert operator_index =~ "operator_id"
      assert operator_index =~ "operator_id IS NOT NULL"
    end

    test "the named check constraints exist on the new tables and on blocking_settings" do
      schema = setup_prefix()
      migrate_up(schema)

      assert constraint_names(schema, "operators") == ["seniority_number_range"]

      assert constraint_names(schema, "roster_lines") == ["line_number_positive"]

      assert Enum.sort(constraint_names(schema, "roster_line_days")) ==
               ["run_id_format", "weekday_range"]

      settings_constraints = constraint_names(schema, "blocking_settings")

      assert "min_rest_range" in settings_constraints
      assert "weekly_hours_warn_range" in settings_constraints
    end

    test "blocking_settings gains three NOT NULL columns with the specified defaults" do
      schema = setup_prefix()
      migrate_up(schema)

      columns =
        schema
        |> table_columns("blocking_settings")
        |> Map.new(&{&1["column_name"], &1})

      assert columns["min_rest_minutes"]["data_type"] == "integer"
      assert columns["min_rest_minutes"]["is_nullable"] == "NO"
      assert columns["min_rest_minutes"]["column_default"] == "600"

      assert columns["weekly_hours_warn_above"]["data_type"] == "integer"
      assert columns["weekly_hours_warn_above"]["is_nullable"] == "NO"
      assert columns["weekly_hours_warn_above"]["column_default"] == "48"

      assert columns["roster_day_types"]["is_nullable"] == "NO"

      %{rows: [[min_rest, warn_above, day_types]]} =
        SQL.query!(
          Repo,
          """
          SELECT min_rest_minutes, weekly_hours_warn_above, roster_day_types
          FROM "#{schema}".blocking_settings
          """,
          []
        )

      assert min_rest == 600
      assert warn_above == 48
      assert day_types == %{}
    end

    test "a stored roster_line_day keeps the run's times it was set with" do
      schema = setup_prefix()
      organization_id = insert_organization(schema, "Org")
      version_id = insert_version(schema, organization_id)
      migrate_up(schema)

      line_id = insert_line(schema, organization_id, version_id, 1, nil)

      :ok =
        insert_line_day(schema, line_id, organization_id, version_id, %{
          weekday: 1,
          day_type_key: "abc",
          run_id: "1005",
          run_sign_on_secs: 19_200,
          run_sign_off_secs: 55_500
        })

      %{rows: rows} =
        SQL.query!(
          Repo,
          """
          SELECT weekday, day_type_key, run_id, run_sign_on_secs, run_sign_off_secs
          FROM "#{schema}".roster_line_days
          """,
          []
        )

      assert rows == [[1, "abc", "1005", 19_200, 55_500]]
    end

    test "the named checks reject values outside their ranges" do
      schema = setup_prefix()
      organization_id = insert_organization(schema, "Org")
      version_id = insert_version(schema, organization_id)
      migrate_up(schema)
      :ok = insert_settings(schema, organization_id, version_id)

      line_id = insert_line(schema, organization_id, version_id, 1, nil)

      assert_raise Postgrex.Error, ~r/weekday_range/, fn ->
        insert_line_day(schema, line_id, organization_id, version_id, %{
          weekday: 8,
          day_type_key: "abc",
          run_id: "1005",
          run_sign_on_secs: 0,
          run_sign_off_secs: 0
        })
      end

      assert_raise Postgrex.Error, ~r/run_id_format/, fn ->
        insert_line_day(schema, line_id, organization_id, version_id, %{
          weekday: 1,
          day_type_key: "abc",
          run_id: "1005 6",
          run_sign_on_secs: 0,
          run_sign_off_secs: 0
        })
      end

      assert_raise Postgrex.Error, ~r/seniority_number_range/, fn ->
        insert_operator(schema, organization_id, "E1", "Aurelia Nowak", 100_000)
      end

      assert_raise Postgrex.Error, ~r/line_number_positive/, fn ->
        insert_line(schema, organization_id, version_id, 0, nil)
      end

      assert_raise Postgrex.Error, ~r/min_rest_range/, fn ->
        update_settings(schema, version_id, "min_rest_minutes", 479)
      end

      assert_raise Postgrex.Error, ~r/weekly_hours_warn_range/, fn ->
        update_settings(schema, version_id, "weekly_hours_warn_above", 61)
      end
    end
  end

  describe "down/0 reversibility" do
    test "down removes the three tables, the roster settings columns and their constraints" do
      schema = setup_prefix()
      organization_id = insert_organization(schema, "Org")
      version_id = insert_version(schema, organization_id)
      :ok = insert_settings(schema, organization_id, version_id)

      migrate_up(schema)
      assert table_exists?(schema, "roster_line_days")

      migrate_down(schema)

      refute table_exists?(schema, "operators")
      refute table_exists?(schema, "roster_lines")
      refute table_exists?(schema, "roster_line_days")

      settings_names =
        schema
        |> table_columns("blocking_settings")
        |> Enum.map(& &1["column_name"])

      refute "min_rest_minutes" in settings_names
      refute "weekly_hours_warn_above" in settings_names
      refute "roster_day_types" in settings_names

      refute "min_rest_range" in constraint_names(schema, "blocking_settings")
      refute "weekly_hours_warn_range" in constraint_names(schema, "blocking_settings")

      # The version's own block settings survive the rollback.
      assert fetch_min_layover(schema) == 5
    end

    test "a second up after down succeeds and restores the roster shape" do
      schema = setup_prefix()
      migrate_up(schema)
      migrate_down(schema)
      migrate_up(schema)

      assert table_exists?(schema, "operators")
      assert table_exists?(schema, "roster_lines")
      assert table_exists?(schema, "roster_line_days")

      assert "roster_line_days_run_once_per_weekday" in index_names(schema, "roster_line_days")

      assert "min_rest_range" in constraint_names(schema, "blocking_settings")
    end
  end

  # --- helpers -------------------------------------------------------------

  defp setup_prefix do
    schema = "test_basic_rosters_#{System.unique_integer([:positive])}"

    SQL.query!(Repo, ~s|CREATE SCHEMA "#{schema}"|, [])

    on_exit(fn ->
      SQL.query!(Repo, ~s|DROP SCHEMA IF EXISTS "#{schema}" CASCADE|, [])
    end)

    SQL.query!(
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

    SQL.query!(
      Repo,
      """
      CREATE TABLE "#{schema}".gtfs_versions (
        id uuid PRIMARY KEY,
        organization_id uuid NOT NULL REFERENCES "#{schema}".organizations(id) ON DELETE CASCADE,
        name varchar(255) NOT NULL,
        inserted_at timestamp(6) NOT NULL DEFAULT now(),
        updated_at timestamp(6) NOT NULL DEFAULT now()
      )
      """,
      []
    )

    # Only the pre-roster blocking_settings columns the migration extends; the
    # unit tests of the real migrated database own the rest.
    SQL.query!(
      Repo,
      """
      CREATE TABLE "#{schema}".blocking_settings (
        id uuid PRIMARY KEY,
        organization_id uuid NOT NULL REFERENCES "#{schema}".organizations(id) ON DELETE CASCADE,
        gtfs_version_id uuid NOT NULL,
        min_layover_minutes integer NOT NULL DEFAULT 5,
        inserted_at timestamp(6) NOT NULL DEFAULT now(),
        updated_at timestamp(6) NOT NULL DEFAULT now()
      )
      """,
      []
    )

    schema
  end

  defp insert_organization(schema, name) do
    id = Ecto.UUID.generate()

    SQL.query!(
      Repo,
      ~s|INSERT INTO "#{schema}".organizations (id, name) VALUES ($1, $2)|,
      [dump(id), name]
    )

    id
  end

  defp insert_version(schema, organization_id) do
    id = Ecto.UUID.generate()

    SQL.query!(
      Repo,
      """
      INSERT INTO "#{schema}".gtfs_versions (id, organization_id, name)
      VALUES ($1, $2, 'Fall 2026')
      """,
      [dump(id), dump(organization_id)]
    )

    id
  end

  defp insert_settings(schema, organization_id, version_id) do
    id = Ecto.UUID.generate()

    SQL.query!(
      Repo,
      """
      INSERT INTO "#{schema}".blocking_settings
        (id, organization_id, gtfs_version_id, min_layover_minutes)
      VALUES ($1, $2, $3, 5)
      """,
      [dump(id), dump(organization_id), dump(version_id)]
    )

    :ok
  end

  defp update_settings(schema, version_id, column, value) do
    SQL.query!(
      Repo,
      ~s|UPDATE "#{schema}".blocking_settings SET #{column} = $1 WHERE gtfs_version_id = $2|,
      [value, dump(version_id)]
    )

    :ok
  end

  defp fetch_min_layover(schema) do
    %{rows: [[min_layover]]} =
      SQL.query!(
        Repo,
        ~s|SELECT min_layover_minutes FROM "#{schema}".blocking_settings|,
        []
      )

    min_layover
  end

  defp insert_operator(schema, organization_id, employee_id, display_name, seniority_number) do
    id = Ecto.UUID.generate()

    SQL.query!(
      Repo,
      """
      INSERT INTO "#{schema}".operators
        (id, organization_id, employee_id, display_name, seniority_number, inserted_at, updated_at)
      VALUES ($1, $2, $3, $4, $5, $6, $6)
      """,
      [
        dump(id),
        dump(organization_id),
        employee_id,
        display_name,
        seniority_number,
        @now
      ]
    )

    id
  end

  defp insert_line(schema, organization_id, version_id, line_number, operator_id) do
    id = Ecto.UUID.generate()

    SQL.query!(
      Repo,
      """
      INSERT INTO "#{schema}".roster_lines
        (id, organization_id, gtfs_version_id, line_number, operator_id, inserted_at, updated_at)
      VALUES ($1, $2, $3, $4, $5, $6, $6)
      """,
      [dump(id), dump(organization_id), dump(version_id), line_number, dump(operator_id), @now]
    )

    id
  end

  defp insert_line_day(schema, roster_line_id, organization_id, version_id, attrs) do
    id = Ecto.UUID.generate()

    SQL.query!(
      Repo,
      """
      INSERT INTO "#{schema}".roster_line_days (
        id, roster_line_id, organization_id, gtfs_version_id,
        weekday, day_type_key, run_id, run_sign_on_secs, run_sign_off_secs,
        inserted_at, updated_at
      )
      VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $10)
      """,
      [
        dump(id),
        dump(roster_line_id),
        dump(organization_id),
        dump(version_id),
        attrs.weekday,
        attrs.day_type_key,
        attrs.run_id,
        attrs.run_sign_on_secs,
        attrs.run_sign_off_secs,
        @now
      ]
    )

    :ok
  end

  defp migrate_up(schema) do
    Ecto.Migrator.up(Repo, @migration_version, Migration, prefix: schema, log: false)
  end

  defp migrate_down(schema) do
    Ecto.Migrator.down(Repo, @migration_version, Migration, prefix: schema, log: false)
  end

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

  defp table_columns(schema, table) do
    %{rows: rows, columns: columns} =
      SQL.query!(
        Repo,
        """
        SELECT column_name, data_type, udt_name, is_nullable, column_default
        FROM information_schema.columns
        WHERE table_schema = $1 AND table_name = $2
        ORDER BY ordinal_position
        """,
        [schema, table]
      )

    Enum.map(rows, fn row ->
      columns |> Enum.zip(row) |> Map.new()
    end)
  end

  defp index_names(schema, table) do
    schema
    |> table_index_defs(table)
    |> Enum.map(& &1["indexname"])
    |> Enum.sort()
  end

  defp table_index_defs(schema, table) do
    %{rows: rows, columns: columns} =
      SQL.query!(
        Repo,
        """
        SELECT indexname, indexdef FROM pg_indexes
        WHERE schemaname = $1 AND tablename = $2
        """,
        [schema, table]
      )

    Enum.map(rows, fn row ->
      columns |> Enum.zip(row) |> Map.new()
    end)
  end

  defp constraint_names(schema, table) do
    %{rows: rows} =
      SQL.query!(
        Repo,
        """
        SELECT con.conname FROM pg_constraint con
        JOIN pg_namespace ns ON ns.oid = con.connamespace
        JOIN pg_class cls ON cls.oid = con.conrelid
        WHERE ns.nspname = $1 AND cls.relname = $2 AND con.contype = 'c'
        """,
        [schema, table]
      )

    rows |> List.flatten() |> Enum.sort()
  end

  defp dump(nil), do: nil
  defp dump(uuid), do: Ecto.UUID.dump!(uuid)
end
