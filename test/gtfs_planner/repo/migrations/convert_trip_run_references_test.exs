defmodule GtfsPlanner.Repo.Migrations.ConvertTripRunReferencesTest do
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL
  alias Ecto.Adapters.SQL.Sandbox
  alias Ecto.Migrator

  alias GtfsPlanner.Repo

  @migration_path Path.expand(
                    "../../../../priv/repo/migrations/20261003055721_convert_trip_run_references_to_gtfs_ids.exs",
                    __DIR__
                  )
  Code.require_file(@migration_path)

  @migration_version @migration_path
                     |> Path.basename()
                     |> String.split("_", parts: 2)
                     |> hd()
                     |> String.to_integer()

  alias GtfsPlanner.Repo.Migrations.ConvertTripRunReferencesToGtfsIds, as: Migration

  setup_all do
    Sandbox.mode(Repo, :auto)
    on_exit(fn -> Sandbox.mode(Repo, :manual) end)
    :ok
  end

  describe "up/0" do
    test "stores T1 on each assignment of its own scope and keeps the assignment rows" do
      prefix = setup_prefix()
      org = Ecto.UUID.generate()
      org_b = Ecto.UUID.generate()
      version = Ecto.UUID.generate()
      sibling_version = Ecto.UUID.generate()
      version_b = Ecto.UUID.generate()

      # The same trip ID exists in a sibling version and another organization,
      # each with its own assignment; every row must resolve to its own trip.
      t1 = insert_trip(prefix, org, version, "T1")
      t2 = insert_trip(prefix, org, version, "T2")
      sibling = insert_trip(prefix, org, sibling_version, "T1")
      foreign = insert_trip(prefix, org_b, version_b, "T1")

      weekday = insert_assignment(prefix, t1, org, version, "WK", "101")
      saturday = insert_assignment(prefix, t1, org, version, "SA", "7")
      second = insert_assignment(prefix, t2, org, version, "WK", "102")
      sibling_row = insert_assignment(prefix, sibling, org, sibling_version, "WK", "202")
      foreign_row = insert_assignment(prefix, foreign, org_b, version_b, "WK", "303")

      Migrator.up(Repo, @migration_version, Migration, prefix: prefix, log: false)

      assert assignments(prefix) == %{
               weekday => {org, version, "WK", "T1", "101"},
               saturday => {org, version, "SA", "T1", "7"},
               second => {org, version, "WK", "T2", "102"},
               sibling_row => {org, sibling_version, "WK", "T1", "202"},
               foreign_row => {org_b, version_b, "WK", "T1", "303"}
             }

      assert [["NO", "character varying"]] = trip_id_column(prefix)
    end

    test "refuses to convert when an assignment cannot be resolved in its own scope" do
      prefix = setup_prefix()
      org = Ecto.UUID.generate()
      other_org = Ecto.UUID.generate()
      version = Ecto.UUID.generate()
      other_version = Ecto.UUID.generate()

      healthy_trip = insert_trip(prefix, org, version, "T1")
      healthy = insert_assignment(prefix, healthy_trip, org, version, "WK", "101")

      # An assignment naming a trip row of another organization cannot be
      # translated without guessing that organization's trip.
      foreign_trip = insert_trip(prefix, other_org, other_version, "T1")
      drop_owner_keys(prefix)
      orphan = insert_assignment(prefix, foreign_trip, org, version, "WK", "102")

      error =
        assert_raise Postgrex.Error, ~r/could not be resolved to a scoped trip/, fn ->
          Migrator.up(Repo, @migration_version, Migration, prefix: prefix, log: false)
        end

      # The diagnostic names the unresolved row and its fields, not healthy rows.
      assert error.postgres.message =~ "trip_runs id=#{orphan}"
      assert error.postgres.message =~ "organization_id=#{org}"
      assert error.postgres.message =~ "trip_id=#{foreign_trip}"
      refute error.postgres.message =~ healthy

      # Nothing was converted.
      assert [["NO", "uuid"]] = trip_id_column(prefix)
    end
  end

  describe "down/0" do
    test "restores trip row UUIDs when the scoped trips still exist" do
      prefix = setup_prefix()
      org = Ecto.UUID.generate()
      version = Ecto.UUID.generate()
      sibling_version = Ecto.UUID.generate()

      trip = insert_trip(prefix, org, version, "T1")
      _sibling_trip = insert_trip(prefix, org, sibling_version, "T1")
      row = insert_assignment(prefix, trip, org, version, "WK", "101")

      Migrator.up(Repo, @migration_version, Migration, prefix: prefix, log: false)
      Migrator.down(Repo, @migration_version, Migration, prefix: prefix, log: false)

      assert %{rows: [[^trip]]} =
               SQL.query!(
                 Repo,
                 "SELECT trip_id::text FROM #{q(prefix)}.trip_runs WHERE id = '#{row}'",
                 []
               )
    end

    test "refuses to roll back when a scoped trip is missing" do
      prefix = setup_prefix()
      org = Ecto.UUID.generate()
      version = Ecto.UUID.generate()

      trip = insert_trip(prefix, org, version, "T1")
      row = insert_assignment(prefix, trip, org, version, "WK", "101")

      Migrator.up(Repo, @migration_version, Migration, prefix: prefix, log: false)

      SQL.query!(
        Repo,
        "ALTER TABLE #{q(prefix)}.trip_runs DROP CONSTRAINT trip_runs_trips_owner_fkey",
        []
      )

      SQL.query!(Repo, "DELETE FROM #{q(prefix)}.trips WHERE id = '#{trip}'", [])

      assert_raise Postgrex.Error, ~r/cannot be restored to row UUIDs/, fn ->
        Migrator.down(Repo, @migration_version, Migration, prefix: prefix, log: false)
      end

      assert {_, _, _, "T1", _} = assignments(prefix)[row]
    end
  end

  describe "converted schema" do
    setup do
      prefix = setup_prefix()
      org = Ecto.UUID.generate()
      version = Ecto.UUID.generate()
      other_version = Ecto.UUID.generate()

      trip = insert_trip(prefix, org, version, "T1")
      sibling = insert_trip(prefix, org, other_version, "T1")
      row = insert_assignment(prefix, trip, org, version, "WK", "101")
      sibling_row = insert_assignment(prefix, sibling, org, other_version, "WK", "202")

      Migrator.up(Repo, @migration_version, Migration, prefix: prefix, log: false)

      {:ok,
       prefix: prefix,
       org: org,
       version: version,
       other_version: other_version,
       trip: trip,
       row: row,
       sibling_row: sibling_row}
    end

    test "a trip ID rename follows into its own scope's assignment only", context do
      SQL.query!(
        Repo,
        "UPDATE #{q(context.prefix)}.trips SET trip_id = 'T9' WHERE id = '#{context.trip}'",
        []
      )

      trip_ids = assignments(context.prefix)

      assert {_, _, _, "T9", "101"} = trip_ids[context.row]
      assert {_, _, _, "T1", "202"} = trip_ids[context.sibling_row]
    end

    test "deleting a trip removes its own scope's assignment only", context do
      SQL.query!(Repo, "DELETE FROM #{q(context.prefix)}.trips WHERE id = '#{context.trip}'", [])

      assert Map.keys(assignments(context.prefix)) == [context.sibling_row]
    end

    test "a trip ID that exists only in another scope is not a parent", context do
      insert_trip(context.prefix, context.org, context.other_version, "ONLY-ELSEWHERE")

      assert_raise Postgrex.Error, ~r/trip_runs_trips_owner_fkey/, fn ->
        insert_natural_assignment(
          context.prefix,
          "ONLY-ELSEWHERE",
          context.org,
          context.version,
          "WK",
          "103"
        )
      end
    end

    test "a trip holds one assignment per day type of its own scope", context do
      assert_raise Postgrex.Error,
                   ~r/trip_runs_organization_id_gtfs_version_id_day_type_key/,
                   fn ->
                     insert_natural_assignment(
                       context.prefix,
                       "T1",
                       context.org,
                       context.version,
                       "WK",
                       "103"
                     )
                   end

      # Another day type of the same trip, and the same day type in a sibling
      # version's own trip, store beside it.
      insert_natural_assignment(context.prefix, "T1", context.org, context.version, "SA", "103")

      assert Enum.count(assignments(context.prefix)) == 3
    end
  end

  defp q(prefix), do: ~s|"#{prefix}"|

  defp trip_id_column(prefix) do
    %{rows: rows} =
      SQL.query!(
        Repo,
        """
        SELECT is_nullable, data_type FROM information_schema.columns
        WHERE table_schema = $1 AND table_name = 'trip_runs' AND column_name = 'trip_id'
        """,
        [prefix]
      )

    rows
  end

  defp assignments(prefix) do
    %{rows: rows} =
      SQL.query!(
        Repo,
        """
        SELECT id::text, organization_id::text, gtfs_version_id::text, day_type_key,
               trip_id::text, run_id
        FROM #{q(prefix)}.trip_runs
        """,
        []
      )

    Map.new(rows, fn [id, org, version, day_type, trip_id, run_id] ->
      {id, {org, version, day_type, trip_id, run_id}}
    end)
  end

  defp drop_owner_keys(prefix) do
    for statement <- [
          "ALTER TABLE #{q(prefix)}.trip_runs DROP CONSTRAINT trip_runs_trip_id_fkey",
          "ALTER TABLE #{q(prefix)}.trip_runs DROP CONSTRAINT trip_runs_trips_owner_fkey"
        ] do
      SQL.query!(Repo, statement, [])
    end
  end

  # The pre-conversion schema: `trip_runs.trip_id` holds the `trips.id` row UUID,
  # with the single-column cascade reference and the composite owner key beside it.
  defp setup_prefix do
    prefix = "test_convert_trip_run_#{System.unique_integer([:positive])}"
    SQL.query!(Repo, ~s|CREATE SCHEMA "#{prefix}"|, [])

    on_exit(fn -> SQL.query!(Repo, ~s|DROP SCHEMA IF EXISTS "#{prefix}" CASCADE|, []) end)

    for statement <- [
          """
          CREATE TABLE #{q(prefix)}.trips (
            id uuid PRIMARY KEY,
            organization_id uuid NOT NULL,
            gtfs_version_id uuid NOT NULL,
            trip_id varchar(255) NOT NULL,
            inserted_at timestamp(6) NOT NULL,
            updated_at timestamp(6) NOT NULL
          )
          """,
          """
          CREATE UNIQUE INDEX trips_organization_id_gtfs_version_id_trip_id_index
          ON #{q(prefix)}.trips (organization_id, gtfs_version_id, trip_id)
          """,
          """
          CREATE UNIQUE INDEX trips_id_organization_id_gtfs_version_id_owner_index
          ON #{q(prefix)}.trips (id, organization_id, gtfs_version_id)
          """,
          """
          CREATE TABLE #{q(prefix)}.trip_runs (
            id uuid PRIMARY KEY,
            organization_id uuid NOT NULL,
            gtfs_version_id uuid NOT NULL,
            trip_id uuid NOT NULL
              CONSTRAINT trip_runs_trip_id_fkey
              REFERENCES #{q(prefix)}.trips (id) ON DELETE CASCADE,
            day_type_key varchar(255) NOT NULL,
            run_id varchar(255) NOT NULL,
            inserted_at timestamp(6) NOT NULL,
            updated_at timestamp(6) NOT NULL,
            CONSTRAINT run_id_format CHECK (run_id ~ '^[A-Za-z0-9-]{1,8}$')
          )
          """,
          """
          CREATE UNIQUE INDEX trip_runs_organization_id_gtfs_version_id_day_type_key_trip_id_
          ON #{q(prefix)}.trip_runs (organization_id, gtfs_version_id, day_type_key, trip_id)
          """,
          """
          CREATE INDEX trip_runs_organization_id_gtfs_version_id_day_type_key_run_id_i
          ON #{q(prefix)}.trip_runs (organization_id, gtfs_version_id, day_type_key, run_id)
          """,
          "CREATE INDEX trip_runs_trip_id_index ON #{q(prefix)}.trip_runs (trip_id)",
          """
          ALTER TABLE #{q(prefix)}.trip_runs
            ADD CONSTRAINT trip_runs_trips_owner_fkey
            FOREIGN KEY (trip_id, organization_id, gtfs_version_id)
            REFERENCES #{q(prefix)}.trips (id, organization_id, gtfs_version_id)
          """
        ] do
      SQL.query!(Repo, statement, [])
    end

    prefix
  end

  defp insert_trip(prefix, org, version, trip_id) do
    id = Ecto.UUID.generate()

    SQL.query!(
      Repo,
      """
      INSERT INTO #{q(prefix)}.trips
        (id, organization_id, gtfs_version_id, trip_id, inserted_at, updated_at)
      VALUES (#{uuid(id)}, #{uuid(org)}, #{uuid(version)}, $1, now(), now())
      """,
      [trip_id]
    )

    id
  end

  # Before the conversion an assignment names its trip by row UUID.
  defp insert_assignment(prefix, trip, org, version, day_type_key, run_id) do
    id = Ecto.UUID.generate()

    SQL.query!(
      Repo,
      """
      INSERT INTO #{q(prefix)}.trip_runs
        (id, organization_id, gtfs_version_id, trip_id, day_type_key, run_id,
         inserted_at, updated_at)
      VALUES (#{uuid(id)}, #{uuid(org)}, #{uuid(version)}, #{uuid(trip)}, $1, $2, now(), now())
      """,
      [day_type_key, run_id]
    )

    id
  end

  # After the conversion it names the trip's GTFS ID.
  defp insert_natural_assignment(prefix, trip_id, org, version, day_type_key, run_id) do
    id = Ecto.UUID.generate()

    SQL.query!(
      Repo,
      """
      INSERT INTO #{q(prefix)}.trip_runs
        (id, organization_id, gtfs_version_id, trip_id, day_type_key, run_id,
         inserted_at, updated_at)
      VALUES (#{uuid(id)}, #{uuid(org)}, #{uuid(version)}, $1, $2, $3, now(), now())
      """,
      [trip_id, day_type_key, run_id]
    )

    id
  end

  defp uuid(value), do: ~s|'#{value}'::uuid|
end
