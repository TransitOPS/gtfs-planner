defmodule GtfsPlanner.Repo.Migrations.AddZoneIdToStopsTest do
  # `Ecto.Migrator` runs the migration in a separate task process, which cannot
  # share the DataCase sandbox transaction. Run against real autocommit connections
  # in `:auto` mode and isolate all DDL and writes in a unique PostgreSQL schema
  # holding a stand-in `stops` table, dropped on exit. The public tables are never
  # touched.
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL
  alias Ecto.Adapters.SQL.Sandbox
  alias Ecto.Changeset
  alias Ecto.Migrator
  alias GtfsPlanner.Gtfs.Stop
  alias GtfsPlanner.Repo

  @migration_glob "../../../../priv/repo/migrations/*_add_zone_id_to_stops.exs"

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

  alias GtfsPlanner.Repo.Migrations.AddZoneIdToStops, as: Migration

  @index "stops_organization_id_gtfs_version_id_zone_id_index"

  @stand_in_columns ~w(id location_type organization_id stop_id stop_name gtfs_version_id)

  setup_all do
    Sandbox.mode(Repo, :auto)
    on_exit(fn -> Sandbox.mode(Repo, :manual) end)
    :ok
  end

  describe "up" do
    setup do
      schema = create_schema()
      %{schema: schema, rows: insert_stand_in_rows!(schema)}
    end

    test "keeps both stand-in rows and leaves zone_id NULL", %{schema: schema, rows: rows} do
      migrate_up!(schema)

      assert stand_in_rows(schema) == rows
      assert zone_ids(schema) == [nil, nil]
    end

    test "adds a nullable character varying zone_id column with no default", %{schema: schema} do
      migrate_up!(schema)

      assert column(schema, "zone_id") == %{
               data_type: "character varying",
               is_nullable: "YES",
               column_default: nil
             }
    end

    test "adds the organization, version and zone index", %{schema: schema} do
      migrate_up!(schema)

      assert index_definition(schema, @index) ==
               "CREATE INDEX #{@index} ON #{schema}.stops USING btree " <>
                 "(organization_id, gtfs_version_id, zone_id)"
    end
  end

  describe "down" do
    setup do
      schema = create_schema()
      %{schema: schema, rows: insert_stand_in_rows!(schema)}
    end

    test "drops only zone_id and its index, keeping every row and column", %{
      schema: schema,
      rows: rows
    } do
      migrate_up!(schema)

      Migrator.down(Repo, @migration_version, Migration, prefix: schema, log: false)

      refute "zone_id" in table_columns(schema, "stops")
      # Both sides are sorted: the assertion is about the same set of columns,
      # and `information_schema` does not promise an order.
      assert Enum.sort(table_columns(schema, "stops")) == Enum.sort(@stand_in_columns)
      refute index_exists?(schema, @index)
      assert stand_in_rows(schema) == rows
    end
  end

  describe "GtfsPlanner.Gtfs.Stop" do
    test "exposes zone_id defaulting to nil" do
      assert %Stop{zone_id: nil} = %Stop{}
    end

    test "changeset/2 ignores a zone_id on a new stop" do
      changeset = Stop.changeset(%Stop{}, %{zone_id: "A"})

      refute Map.has_key?(changeset.changes, :zone_id)
      assert Changeset.get_field(changeset, :zone_id) == nil
    end

    test "changeset/2 cannot clear an assigned zone_id" do
      changeset = Stop.changeset(%Stop{zone_id: "A"}, %{zone_id: nil})

      refute Map.has_key?(changeset.changes, :zone_id)
      assert Changeset.get_field(changeset, :zone_id) == "A"
    end

    test "import_changeset/2 cannot clear an assigned zone_id" do
      changeset = Stop.import_changeset(%Stop{zone_id: "A"}, %{zone_id: nil})

      refute Map.has_key?(changeset.changes, :zone_id)
      assert Changeset.get_field(changeset, :zone_id) == "A"
    end
  end

  defp migrate_up!(schema) do
    Migrator.up(Repo, @migration_version, Migration, prefix: schema, log: false)
  end

  defp create_schema do
    schema = "test_add_zone_id_to_stops_#{System.unique_integer([:positive])}"
    SQL.query!(Repo, ~s|CREATE SCHEMA "#{schema}"|, [])

    on_exit(fn ->
      SQL.query!(Repo, ~s|DROP SCHEMA IF EXISTS "#{schema}" CASCADE|, [])
    end)

    SQL.query!(
      Repo,
      """
      CREATE TABLE "#{schema}".stops (
        id uuid PRIMARY KEY,
        organization_id uuid,
        gtfs_version_id uuid,
        stop_id text,
        stop_name text,
        location_type integer
      )
      """,
      []
    )

    schema
  end

  # Seeds through raw SQL because the migration under test is the only writer.
  defp insert_stand_in_rows!(schema) do
    organization_id = Ecto.UUID.generate()
    version_id = Ecto.UUID.generate()
    first_id = Ecto.UUID.generate()
    second_id = Ecto.UUID.generate()

    insert_stand_in_stop!(schema, first_id, organization_id, version_id, "S1", "Alpha Station", 0)

    insert_stand_in_stop!(
      schema,
      second_id,
      organization_id,
      version_id,
      "S2",
      "Beta Entrance",
      2
    )

    [
      [first_id, "S1", "Alpha Station", 0],
      [second_id, "S2", "Beta Entrance", 2]
    ]
  end

  defp insert_stand_in_stop!(schema, id, organization_id, version_id, stop_id, name, type) do
    SQL.query!(
      Repo,
      """
      INSERT INTO "#{schema}".stops
        (id, organization_id, gtfs_version_id, stop_id, stop_name, location_type)
      VALUES ($1, $2, $3, $4, $5, $6)
      """,
      [dump(id), dump(organization_id), dump(version_id), stop_id, name, type]
    )
  end

  defp stand_in_rows(schema) do
    %{rows: rows} =
      SQL.query!(
        Repo,
        """
        SELECT id::text, stop_id, stop_name, location_type
        FROM "#{schema}".stops
        ORDER BY stop_id
        """,
        []
      )

    rows
  end

  defp zone_ids(schema) do
    %{rows: rows} =
      SQL.query!(Repo, ~s|SELECT zone_id FROM "#{schema}".stops ORDER BY stop_id|, [])

    List.flatten(rows)
  end

  defp table_columns(schema, table) do
    %{rows: rows} =
      SQL.query!(
        Repo,
        """
        SELECT column_name FROM information_schema.columns
        WHERE table_schema = $1 AND table_name = $2
        """,
        [schema, table]
      )

    List.flatten(rows)
  end

  defp column(schema, column) do
    %{rows: [[data_type, is_nullable, column_default]]} =
      SQL.query!(
        Repo,
        """
        SELECT data_type, is_nullable, column_default FROM information_schema.columns
        WHERE table_schema = $1 AND table_name = 'stops' AND column_name = $2
        """,
        [schema, column]
      )

    %{data_type: data_type, is_nullable: is_nullable, column_default: column_default}
  end

  defp index_definition(schema, index) do
    %{rows: [[definition]]} =
      SQL.query!(
        Repo,
        "SELECT indexdef FROM pg_indexes WHERE schemaname = $1 AND indexname = $2",
        [
          schema,
          index
        ]
      )

    definition
  end

  defp index_exists?(schema, index) do
    %{rows: rows} =
      SQL.query!(Repo, "SELECT 1 FROM pg_indexes WHERE schemaname = $1 AND indexname = $2", [
        schema,
        index
      ])

    rows != []
  end

  defp dump(uuid), do: Ecto.UUID.dump!(uuid)
end
