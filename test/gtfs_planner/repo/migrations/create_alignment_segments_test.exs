defmodule GtfsPlanner.Repo.Migrations.CreateAlignmentSegmentsTest do
  # This migration test exercises real DDL (table, partial unique indexes,
  # additive columns, rollback) using Ecto.Migrator against real autocommit
  # connections in :auto mode, isolating all writes in a unique PostgreSQL
  # schema dropped on exit.
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

  @migration_glob "../../../../priv/repo/migrations/*_create_alignment_segments.exs"

  @migration_path (
                    matches = Path.wildcard(Path.expand(@migration_glob, __DIR__))

                    case matches do
                      [path] ->
                        path

                      other ->
                        raise "expected exactly one alignment-segments migration file, got: #{inspect(other)}"
                    end
                  )

  Code.require_file(@migration_path)

  @migration_version @migration_path
                     |> Path.basename()
                     |> String.split("_", parts: 2)
                     |> hd()
                     |> String.to_integer()

  alias GtfsPlanner.Repo.Migrations.CreateAlignmentSegments, as: Migration

  @now ~U[2026-01-01 00:00:00.000000Z]

  describe "up/0 creates the alignment_segments table and shape columns" do
    test "catalog shows the expected columns, defaults and nullability" do
      schema = setup_prefix()
      migrate_up(schema)

      assert table_exists?(schema, "alignment_segments")

      columns = table_columns(schema, "alignment_segments")
      by_name = Map.new(columns, fn col -> {col["column_name"], col} end)

      assert by_name["id"]["data_type"] == "uuid"
      assert by_name["organization_id"]["data_type"] == "uuid"
      assert by_name["organization_id"]["is_nullable"] == "NO"
      assert by_name["gtfs_version_id"]["data_type"] == "uuid"
      assert by_name["gtfs_version_id"]["is_nullable"] == "NO"
      assert by_name["from_stop_id"]["data_type"] == "character varying"
      assert by_name["from_stop_id"]["is_nullable"] == "NO"
      assert by_name["to_stop_id"]["data_type"] == "character varying"
      assert by_name["to_stop_id"]["is_nullable"] == "NO"
      assert by_name["from_occurrence_id"]["data_type"] == "uuid"
      assert by_name["from_occurrence_id"]["is_nullable"] == "YES"
      assert by_name["points"]["data_type"] == "ARRAY"
      assert by_name["points"]["udt_name"] == "_float8"
      assert by_name["points"]["is_nullable"] == "NO"
      assert by_name["points"]["column_default"] == "'{}'::double precision[]"
      assert by_name["lock_version"]["data_type"] == "integer"
      assert by_name["lock_version"]["is_nullable"] == "NO"
      assert by_name["lock_version"]["column_default"] == "1"
      assert by_name["inserted_at"]["is_nullable"] == "NO"
      assert by_name["updated_at"]["is_nullable"] == "NO"

      pattern_columns = table_columns(schema, "route_patterns")
      pattern_by_name = Map.new(pattern_columns, fn col -> {col["column_name"], col} end)

      assert pattern_by_name["shape_id"]["data_type"] == "character varying"
      assert pattern_by_name["shape_id"]["is_nullable"] == "YES"
      assert pattern_by_name["alignment_digest"]["data_type"] == "character varying"
      assert pattern_by_name["alignment_digest"]["is_nullable"] == "YES"

      stop_columns = table_columns(schema, "route_pattern_stops")
      stop_by_name = Map.new(stop_columns, fn col -> {col["column_name"], col} end)

      assert stop_by_name["shape_dist_traveled"]["data_type"] == "numeric"
      assert stop_by_name["shape_dist_traveled"]["is_nullable"] == "YES"
    end

    test "pg_indexes lists the three partial unique indexes" do
      schema = setup_prefix()
      migrate_up(schema)

      segment_indexes = table_index_defs(schema, "alignment_segments")
      by_name = Map.new(segment_indexes, fn row -> {row["indexname"], row["indexdef"]} end)

      shared_def = by_name["alignment_segments_shared_pair_index"]
      assert shared_def =~ "UNIQUE"
      assert shared_def =~ "organization_id"
      assert shared_def =~ "gtfs_version_id"
      assert shared_def =~ "from_stop_id"
      assert shared_def =~ "to_stop_id"
      assert shared_def =~ "from_occurrence_id IS NULL"

      override_def = by_name["alignment_segments_override_visit_index"]
      assert override_def =~ "UNIQUE"
      assert override_def =~ "from_occurrence_id"
      assert override_def =~ "to_stop_id"
      assert override_def =~ "from_occurrence_id IS NOT NULL"

      pattern_indexes = table_index_defs(schema, "route_patterns")

      pattern_by_name =
        Map.new(pattern_indexes, fn row -> {row["indexname"], row["indexdef"]} end)

      owned_def = pattern_by_name["route_patterns_owned_shape_index"]
      assert owned_def =~ "UNIQUE"
      assert owned_def =~ "organization_id"
      assert owned_def =~ "gtfs_version_id"
      assert owned_def =~ "shape_id"
      assert owned_def =~ "shape_id IS NOT NULL"
    end
  end

  describe "shared-pair and override uniqueness" do
    setup do
      schema = setup_prefix()
      org_id = insert_org(schema)
      version_id = insert_version(schema, org_id)
      migrate_up(schema)
      %{schema: schema, org_id: org_id, version_id: version_id}
    end

    test "a second shared row for one pair is rejected; another version succeeds", %{
      schema: schema,
      org_id: org_id,
      version_id: version_id
    } do
      assert :ok = insert_shared_segment(schema, org_id, version_id, "S1", "S2", [])

      assert_raise Postgrex.Error, ~r/alignment_segments_shared_pair_index/, fn ->
        insert_shared_segment(schema, org_id, version_id, "S1", "S2", [])
      end

      version_2_id = insert_version(schema, org_id)
      assert :ok = insert_shared_segment(schema, org_id, version_2_id, "S1", "S2", [])
    end

    test "two overrides for one visit with different stops succeed; a duplicate is rejected",
         %{
           schema: schema,
           org_id: org_id,
           version_id: version_id
         } do
      pattern_id = insert_pattern(schema, org_id, version_id, "P1")
      occurrence_id = insert_occurrence(schema, pattern_id, org_id, version_id, "S1", 1)

      assert :ok = insert_override_segment(schema, org_id, version_id, occurrence_id, "S2", [])
      assert :ok = insert_override_segment(schema, org_id, version_id, occurrence_id, "S3", [])

      assert_raise Postgrex.Error, ~r/alignment_segments_override_visit_index/, fn ->
        insert_override_segment(schema, org_id, version_id, occurrence_id, "S2", [])
      end
    end

    test "duplicate owned shape_id values are rejected; NULL shape_id rows are accepted",
         %{
           schema: schema,
           org_id: org_id,
           version_id: version_id
         } do
      assert is_binary(insert_pattern(schema, org_id, version_id, "P1"))
      assert is_binary(insert_pattern(schema, org_id, version_id, "P2"))

      SQL.query!(
        Repo,
        ~s|UPDATE "#{schema}".route_patterns SET shape_id = 'P1' WHERE route_pattern_id = 'P1'|,
        []
      )

      assert_raise Postgrex.Error, ~r/route_patterns_owned_shape_index/, fn ->
        SQL.query!(
          Repo,
          ~s|UPDATE "#{schema}".route_patterns SET shape_id = 'P1' WHERE route_pattern_id = 'P2'|,
          []
        )
      end
    end

    test "points round-trips the default and an explicit [lon, lat] pair list", %{
      schema: schema,
      org_id: org_id,
      version_id: version_id
    } do
      assert :ok = insert_shared_segment(schema, org_id, version_id, "S1", "S2", :default)

      points = [[-74.006, 40.7128], [-74.005, 40.7138]]
      assert :ok = insert_shared_segment(schema, org_id, version_id, "S2", "S3", points)

      %{rows: [[default_points]]} =
        SQL.query!(
          Repo,
          ~s|SELECT points FROM "#{schema}".alignment_segments WHERE from_stop_id = 'S1' AND to_stop_id = 'S2'|,
          []
        )

      assert default_points == []

      %{rows: [[stored_points]]} =
        SQL.query!(
          Repo,
          ~s|SELECT points FROM "#{schema}".alignment_segments WHERE from_stop_id = 'S2' AND to_stop_id = 'S3'|,
          []
        )

      assert stored_points == points
    end

    test "deleting the referenced visit deletes its override rows", %{
      schema: schema,
      org_id: org_id,
      version_id: version_id
    } do
      pattern_id = insert_pattern(schema, org_id, version_id, "P1")
      occurrence_id = insert_occurrence(schema, pattern_id, org_id, version_id, "S1", 1)
      assert :ok = insert_override_segment(schema, org_id, version_id, occurrence_id, "S2", [])

      assert segment_count(schema) == 1

      SQL.query!(
        Repo,
        ~s|DELETE FROM "#{schema}".route_pattern_stops WHERE id = $1|,
        [dump(occurrence_id)]
      )

      assert segment_count(schema) == 0
    end
  end

  describe "up/down reversibility" do
    test "down removes the table, indexes and columns; pre-existing rows are unchanged" do
      schema = setup_prefix()
      org_id = insert_org(schema)
      version_id = insert_version(schema, org_id)
      pattern_id = insert_pattern(schema, org_id, version_id, "P1")
      _occurrence_id = insert_occurrence(schema, pattern_id, org_id, version_id, "S1", 1)

      pre_patterns = fetch_patterns(schema)
      pre_stops = fetch_occurrences(schema)
      assert length(pre_patterns) == 1
      assert length(pre_stops) == 1

      migrate_up(schema)
      assert table_exists?(schema, "alignment_segments")
      assert fetch_patterns(schema) == pre_patterns
      assert fetch_occurrences(schema) == pre_stops

      assert :ok = insert_shared_segment(schema, org_id, version_id, "S1", "S2", [])

      migrate_down(schema)
      refute table_exists?(schema, "alignment_segments")

      assert table_index_defs(schema, "alignment_segments") == []

      assert table_index_defs(schema, "route_patterns")
             |> Enum.map(& &1["indexname"])
             |> Enum.member?("route_patterns_owned_shape_index") == false

      pattern_names =
        table_columns(schema, "route_patterns") |> Enum.map(& &1["column_name"])

      refute "shape_id" in pattern_names
      refute "alignment_digest" in pattern_names

      stop_names =
        table_columns(schema, "route_pattern_stops") |> Enum.map(& &1["column_name"])

      refute "shape_dist_traveled" in stop_names

      assert fetch_patterns(schema) == pre_patterns
      assert fetch_occurrences(schema) == pre_stops

      migrate_up(schema)
      assert table_exists?(schema, "alignment_segments")
      assert fetch_patterns(schema) == pre_patterns
      assert fetch_occurrences(schema) == pre_stops
    end
  end

  # --- helpers -------------------------------------------------------------

  defp setup_prefix do
    schema = "test_align_segments_#{System.unique_integer([:positive])}"

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
      CREATE TABLE "#{schema}".route_patterns (
        id uuid PRIMARY KEY,
        organization_id uuid NOT NULL REFERENCES "#{schema}".organizations(id) ON DELETE CASCADE,
        gtfs_version_id uuid NOT NULL,
        route_pattern_id varchar(255) NOT NULL,
        route_id varchar(255) NOT NULL,
        headsign varchar(255),
        inserted_at timestamp(6) NOT NULL DEFAULT now(),
        updated_at timestamp(6) NOT NULL DEFAULT now()
      )
      """,
      []
    )

    SQL.query!(
      Repo,
      """
      CREATE TABLE "#{schema}".route_pattern_stops (
        id uuid PRIMARY KEY,
        route_pattern_id uuid NOT NULL REFERENCES "#{schema}".route_patterns(id) ON DELETE CASCADE,
        organization_id uuid NOT NULL REFERENCES "#{schema}".organizations(id) ON DELETE CASCADE,
        gtfs_version_id uuid NOT NULL,
        stop_id varchar(255) NOT NULL,
        position integer NOT NULL,
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

  # The stand-in prefix has no gtfs_versions table; versions are plain UUIDs
  # scoped per test, which is sufficient for the uniqueness-by-version cases.
  defp insert_version(_schema, _org_id), do: Ecto.UUID.generate()

  defp insert_pattern(schema, org_id, version_id, route_pattern_id) do
    id = Ecto.UUID.generate()

    SQL.query!(
      Repo,
      """
      INSERT INTO "#{schema}".route_patterns (
        id, organization_id, gtfs_version_id, route_pattern_id, route_id, inserted_at, updated_at
      ) VALUES ($1, $2, $3, $4, 'R1', $5, $5)
      """,
      [dump(id), dump(org_id), dump(version_id), route_pattern_id, @now]
    )

    id
  end

  defp insert_occurrence(schema, pattern_id, org_id, version_id, stop_id, position) do
    id = Ecto.UUID.generate()

    SQL.query!(
      Repo,
      """
      INSERT INTO "#{schema}".route_pattern_stops (
        id, route_pattern_id, organization_id, gtfs_version_id, stop_id, position, inserted_at, updated_at
      ) VALUES ($1, $2, $3, $4, $5, $6, $7, $7)
      """,
      [dump(id), dump(pattern_id), dump(org_id), dump(version_id), stop_id, position, @now]
    )

    id
  end

  defp insert_shared_segment(schema, org_id, version_id, from_stop_id, to_stop_id, :default) do
    id = Ecto.UUID.generate()

    SQL.query!(
      Repo,
      """
      INSERT INTO "#{schema}".alignment_segments (
        id, organization_id, gtfs_version_id, from_stop_id, to_stop_id, inserted_at, updated_at
      ) VALUES ($1, $2, $3, $4, $5, $6, $6)
      """,
      [dump(id), dump(org_id), dump(version_id), from_stop_id, to_stop_id, @now]
    )

    :ok
  end

  defp insert_shared_segment(schema, org_id, version_id, from_stop_id, to_stop_id, points) do
    id = Ecto.UUID.generate()

    SQL.query!(
      Repo,
      """
      INSERT INTO "#{schema}".alignment_segments (
        id, organization_id, gtfs_version_id, from_stop_id, to_stop_id, points, inserted_at, updated_at
      ) VALUES ($1, $2, $3, $4, $5, $6, $7, $7)
      """,
      [dump(id), dump(org_id), dump(version_id), from_stop_id, to_stop_id, points, @now]
    )

    :ok
  end

  defp insert_override_segment(
         schema,
         org_id,
         version_id,
         occurrence_id,
         to_stop_id,
         points
       ) do
    id = Ecto.UUID.generate()

    %{rows: [[from_stop_id]]} =
      SQL.query!(
        Repo,
        ~s|SELECT stop_id FROM "#{schema}".route_pattern_stops WHERE id = $1|,
        [dump(occurrence_id)]
      )

    SQL.query!(
      Repo,
      """
      INSERT INTO "#{schema}".alignment_segments (
        id, organization_id, gtfs_version_id, from_stop_id, to_stop_id,
        from_occurrence_id, points, inserted_at, updated_at
      ) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $8)
      """,
      [
        dump(id),
        dump(org_id),
        dump(version_id),
        from_stop_id,
        to_stop_id,
        dump(occurrence_id),
        points,
        @now
      ]
    )

    :ok
  end

  defp fetch_patterns(schema) do
    %{rows: rows} =
      SQL.query!(
        Repo,
        ~s|SELECT route_pattern_id, route_id, headsign FROM "#{schema}".route_patterns ORDER BY route_pattern_id|,
        []
      )

    rows
  end

  defp fetch_occurrences(schema) do
    %{rows: rows} =
      SQL.query!(
        Repo,
        ~s|SELECT stop_id, position FROM "#{schema}".route_pattern_stops ORDER BY position|,
        []
      )

    rows
  end

  defp segment_count(schema) do
    %{rows: [[count]]} =
      SQL.query!(Repo, ~s|SELECT count(*) FROM "#{schema}".alignment_segments|, [])

    count
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

    # SQL.query! returns column names as plain strings.
    Enum.map(rows, fn row ->
      columns |> Enum.zip(row) |> Map.new()
    end)
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

  defp dump(uuid), do: Ecto.UUID.dump!(uuid)
end
