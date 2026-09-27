defmodule GtfsPlanner.Repo.Migrations.CreateCalendarAttributesTest do
  # This migration test exercises real DDL (table, unique index, rollback)
  # using Ecto.Migrator against real autocommit connections in :auto mode,
  # isolating all writes in a unique PostgreSQL schema dropped on exit.
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

  @migration_glob "../../../../priv/repo/migrations/*_create_calendar_attributes.exs"

  @migration_path (
                    matches = Path.wildcard(Path.expand(@migration_glob, __DIR__))

                    case matches do
                      [path] ->
                        path

                      other ->
                        raise "expected exactly one calendar-attributes migration file, got: #{inspect(other)}"
                    end
                  )

  Code.require_file(@migration_path)

  @migration_version @migration_path
                     |> Path.basename()
                     |> String.split("_", parts: 2)
                     |> hd()
                     |> String.to_integer()

  alias GtfsPlanner.Repo.Migrations.CreateCalendarAttributes, as: Migration

  @now ~U[2026-01-01 00:00:00.000000Z]

  describe "up/0 adds the calendar_attributes table and indexes" do
    test "the table and scoped unique index exist" do
      schema = setup_prefix()
      migrate_up(schema)

      assert table_exists?(schema, "calendar_attributes")

      names = index_names(schema, "calendar_attributes")

      assert Enum.any?(names, fn name ->
               String.starts_with?(
                 name,
                 "calendar_attributes_organization_id_gtfs_version_id_service_id"
               )
             end),
             "expected unique index on calendar_attributes to exist, got: #{inspect(names)}"
    end
  end

  describe "up/down/up preserves preexisting native rows" do
    test "calendars, calendar_dates, and trips rows remain unchanged across migration cycles" do
      schema = setup_prefix()
      org_id = insert_org(schema)
      version_id = insert_version(schema, org_id)

      # Insert preexisting native rows before migration
      _cal_id = insert_calendar(schema, org_id, version_id, "SVC_PRE_1")
      _cd_id = insert_calendar_date(schema, org_id, version_id, "SVC_PRE_1", ~D[2026-07-04], 1)
      _trip_id = insert_trip(schema, org_id, version_id, "ROUTE_1", "SVC_PRE_1", "TRIP_PRE_1")

      pre_calendars = fetch_calendars(schema)
      pre_dates = fetch_calendar_dates(schema)
      pre_trips = fetch_trips(schema)

      assert length(pre_calendars) == 1
      assert length(pre_dates) == 1
      assert length(pre_trips) == 1

      # Migrate up
      migrate_up(schema)
      assert table_exists?(schema, "calendar_attributes")

      # Verify native rows preserved exactly
      assert fetch_calendars(schema) == pre_calendars
      assert fetch_calendar_dates(schema) == pre_dates
      assert fetch_trips(schema) == pre_trips

      # Insert some calendar_attributes
      insert_calendar_attribute(schema, org_id, version_id, "SVC_PRE_1",
        service_description: "Pre-existing Service",
        service_schedule_name: "Regular Weekday",
        service_schedule_type: "Weekday",
        service_schedule_typicality: 1,
        rating_start_date: ~D[2026-01-01],
        rating_end_date: ~D[2026-06-30],
        rating_description: "Spring 2026"
      )

      # Migrate down
      migrate_down(schema)
      refute table_exists?(schema, "calendar_attributes")

      # Verify native rows still preserved
      assert fetch_calendars(schema) == pre_calendars
      assert fetch_calendar_dates(schema) == pre_dates
      assert fetch_trips(schema) == pre_trips

      # Migrate up again
      migrate_up(schema)
      assert table_exists?(schema, "calendar_attributes")

      # Verify native rows still preserved
      assert fetch_calendars(schema) == pre_calendars
      assert fetch_calendar_dates(schema) == pre_dates
      assert fetch_trips(schema) == pre_trips
    end
  end

  describe "metadata constraints and scope uniqueness" do
    setup do
      schema = setup_prefix()
      org_id = insert_org(schema)
      version_id = insert_version(schema, org_id)
      migrate_up(schema)
      %{schema: schema, org_id: org_id, version_id: version_id}
    end

    test "enforces unique (organization_id, gtfs_version_id, service_id)", %{
      schema: schema,
      org_id: org_id,
      version_id: version_id
    } do
      assert :ok =
               insert_calendar_attribute(schema, org_id, version_id, "SERVICE_1",
                 service_description: "First"
               )

      # Duplicate in same org and version raises unique constraint violation
      assert_raise Postgrex.Error, fn ->
        insert_calendar_attribute(schema, org_id, version_id, "SERVICE_1",
          service_description: "Duplicate"
        )
      end

      # Same service_id in a different version succeeds
      version_2_id = insert_version(schema, org_id)

      assert :ok =
               insert_calendar_attribute(schema, org_id, version_2_id, "SERVICE_1",
                 service_description: "Other Version"
               )

      # Same service_id in a different org succeeds
      org_2_id = insert_org(schema)
      org_2_version_id = insert_version(schema, org_2_id)

      assert :ok =
               insert_calendar_attribute(schema, org_2_id, org_2_version_id, "SERVICE_1",
                 service_description: "Other Org"
               )
    end

    test "allows nil and duplicate descriptions across services", %{
      schema: schema,
      org_id: org_id,
      version_id: version_id
    } do
      assert :ok =
               insert_calendar_attribute(schema, org_id, version_id, "SVC_NIL_1",
                 service_description: nil
               )

      assert :ok =
               insert_calendar_attribute(schema, org_id, version_id, "SVC_NIL_2",
                 service_description: nil
               )

      assert :ok =
               insert_calendar_attribute(schema, org_id, version_id, "SVC_DUP_1",
                 service_description: "Shared Description"
               )

      assert :ok =
               insert_calendar_attribute(schema, org_id, version_id, "SVC_DUP_2",
                 service_description: "Shared Description"
               )
    end
  end

  # --- helpers -------------------------------------------------------------

  defp setup_prefix do
    schema = "test_cal_attrs_#{System.unique_integer([:positive])}"

    SQL.query!(Repo, ~s|CREATE SCHEMA "#{schema}"|, [])

    on_exit(fn ->
      SQL.query!(
        Repo,
        ~s|DROP SCHEMA IF EXISTS "#{schema}" CASCADE|,
        []
      )
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
        name varchar(255) NOT NULL DEFAULT 'First Version',
        inserted_at timestamp(6) NOT NULL,
        updated_at timestamp(6) NOT NULL
      )
      """,
      []
    )

    SQL.query!(
      Repo,
      """
      CREATE TABLE "#{schema}".calendars (
        id uuid PRIMARY KEY,
        organization_id uuid NOT NULL REFERENCES "#{schema}".organizations(id) ON DELETE CASCADE,
        gtfs_version_id uuid NOT NULL,
        service_id varchar(255) NOT NULL,
        monday integer NOT NULL,
        tuesday integer NOT NULL,
        wednesday integer NOT NULL,
        thursday integer NOT NULL,
        friday integer NOT NULL,
        saturday integer NOT NULL,
        sunday integer NOT NULL,
        start_date date NOT NULL,
        end_date date NOT NULL,
        inserted_at timestamp(6) NOT NULL DEFAULT now(),
        updated_at timestamp(6) NOT NULL DEFAULT now()
      )
      """,
      []
    )

    SQL.query!(
      Repo,
      """
      CREATE TABLE "#{schema}".calendar_dates (
        id uuid PRIMARY KEY,
        organization_id uuid NOT NULL REFERENCES "#{schema}".organizations(id) ON DELETE CASCADE,
        gtfs_version_id uuid NOT NULL,
        service_id varchar(255) NOT NULL,
        date date NOT NULL,
        exception_type integer NOT NULL,
        inserted_at timestamp(6) NOT NULL DEFAULT now(),
        updated_at timestamp(6) NOT NULL DEFAULT now()
      )
      """,
      []
    )

    SQL.query!(
      Repo,
      """
      CREATE TABLE "#{schema}".trips (
        id uuid PRIMARY KEY,
        organization_id uuid NOT NULL REFERENCES "#{schema}".organizations(id) ON DELETE CASCADE,
        gtfs_version_id uuid NOT NULL,
        route_id varchar(255) NOT NULL,
        service_id varchar(255) NOT NULL,
        trip_id varchar(255) NOT NULL,
        trip_headsign varchar(255),
        trip_short_name varchar(255),
        direction_id integer NOT NULL,
        block_id varchar(255),
        shape_id varchar(255),
        wheelchair_accessible integer,
        bikes_allowed integer,
        route_pattern_id varchar(255),
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

    SQL.query!(
      Repo,
      ~s|INSERT INTO "#{schema}".organizations (id, name) VALUES ($1, $2)|,
      [dump(id), "Org #{System.unique_integer([:positive])}"]
    )

    id
  end

  defp insert_version(schema, org_id) do
    id = Ecto.UUID.generate()

    SQL.query!(
      Repo,
      ~s|INSERT INTO "#{schema}".gtfs_versions (id, organization_id, name, inserted_at, updated_at) VALUES ($1, $2, $3, $4, $4)|,
      [dump(id), dump(org_id), "Version #{System.unique_integer([:positive])}", @now]
    )

    id
  end

  defp insert_calendar(schema, org_id, version_id, service_id) do
    id = Ecto.UUID.generate()

    SQL.query!(
      Repo,
      """
      INSERT INTO "#{schema}".calendars (
        id, organization_id, gtfs_version_id, service_id,
        monday, tuesday, wednesday, thursday, friday, saturday, sunday,
        start_date, end_date, inserted_at, updated_at
      ) VALUES ($1, $2, $3, $4, 1, 1, 1, 1, 1, 0, 0, $5, $6, $7, $7)
      """,
      [dump(id), dump(org_id), dump(version_id), service_id, ~D[2026-01-01], ~D[2026-12-31], @now]
    )

    id
  end

  defp insert_calendar_date(schema, org_id, version_id, service_id, date, exception_type) do
    id = Ecto.UUID.generate()

    SQL.query!(
      Repo,
      """
      INSERT INTO "#{schema}".calendar_dates (
        id, organization_id, gtfs_version_id, service_id,
        date, exception_type, inserted_at, updated_at
      ) VALUES ($1, $2, $3, $4, $5, $6, $7, $7)
      """,
      [dump(id), dump(org_id), dump(version_id), service_id, date, exception_type, @now]
    )

    id
  end

  defp insert_trip(schema, org_id, version_id, route_id, service_id, trip_id) do
    id = Ecto.UUID.generate()

    SQL.query!(
      Repo,
      """
      INSERT INTO "#{schema}".trips (
        id, organization_id, gtfs_version_id, route_id, service_id, trip_id,
        direction_id, inserted_at, updated_at
      ) VALUES ($1, $2, $3, $4, $5, $6, 0, $7, $7)
      """,
      [dump(id), dump(org_id), dump(version_id), route_id, service_id, trip_id, @now]
    )

    id
  end

  defp insert_calendar_attribute(schema, org_id, version_id, service_id, opts) do
    id = Ecto.UUID.generate()
    desc = Keyword.get(opts, :service_description)
    name = Keyword.get(opts, :service_schedule_name)
    type = Keyword.get(opts, :service_schedule_type)
    typicality = Keyword.get(opts, :service_schedule_typicality, 0)
    rating_start = Keyword.get(opts, :rating_start_date)
    rating_end = Keyword.get(opts, :rating_end_date)
    rating_desc = Keyword.get(opts, :rating_description)

    SQL.query!(
      Repo,
      """
      INSERT INTO "#{schema}".calendar_attributes (
        id, organization_id, gtfs_version_id, service_id,
        service_description, service_schedule_name, service_schedule_type,
        service_schedule_typicality, rating_start_date, rating_end_date,
        rating_description, inserted_at, updated_at
      ) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $12)
      """,
      [
        dump(id),
        dump(org_id),
        dump(version_id),
        service_id,
        desc,
        name,
        type,
        typicality,
        rating_start,
        rating_end,
        rating_desc,
        @now
      ]
    )

    :ok
  end

  defp fetch_calendars(schema) do
    %{rows: rows} =
      SQL.query!(
        Repo,
        ~s|SELECT service_id, monday, tuesday, wednesday, thursday, friday, saturday, sunday, start_date, end_date FROM "#{schema}".calendars ORDER BY service_id|,
        []
      )

    rows
  end

  defp fetch_calendar_dates(schema) do
    %{rows: rows} =
      SQL.query!(
        Repo,
        ~s|SELECT service_id, date, exception_type FROM "#{schema}".calendar_dates ORDER BY service_id, date|,
        []
      )

    rows
  end

  defp fetch_trips(schema) do
    %{rows: rows} =
      SQL.query!(
        Repo,
        ~s|SELECT route_id, service_id, trip_id, direction_id FROM "#{schema}".trips ORDER BY trip_id|,
        []
      )

    rows
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

  defp index_names(schema, table) do
    %{rows: rows} =
      SQL.query!(
        Repo,
        """
        SELECT indexname FROM pg_indexes
        WHERE schemaname = $1 AND tablename = $2
        """,
        [schema, table]
      )

    List.flatten(rows)
  end

  defp dump(uuid), do: Ecto.UUID.dump!(uuid)
end
