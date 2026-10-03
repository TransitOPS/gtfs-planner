defmodule GtfsPlanner.Repo.Migrations.ConvertPatternReferencesTest do
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL
  alias Ecto.Adapters.SQL.Sandbox
  alias Ecto.Migrator

  alias GtfsPlanner.Repo

  @migration_path Path.expand(
                    "../../../../priv/repo/migrations/20261003043732_convert_pattern_references_to_gtfs_ids.exs",
                    __DIR__
                  )
  Code.require_file(@migration_path)

  @migration_version @migration_path
                     |> Path.basename()
                     |> String.split("_", parts: 2)
                     |> hd()
                     |> String.to_integer()

  alias GtfsPlanner.Repo.Migrations.ConvertPatternReferencesToGtfsIds, as: Migration

  setup_all do
    Sandbox.mode(Repo, :auto)
    on_exit(fn -> Sandbox.mode(Repo, :manual) end)
    :ok
  end

  describe "up/0" do
    test "stores P on each A-B-A occurrence and timing variant and keeps their row identities" do
      prefix = setup_prefix()
      org = Ecto.UUID.generate()
      org_b = Ecto.UUID.generate()
      version = Ecto.UUID.generate()
      sibling_version = Ecto.UUID.generate()
      version_b = Ecto.UUID.generate()

      # The same natural ID `P` exists in a sibling version and another
      # organization with different content; each row must resolve to its own.
      pattern = insert_pattern(prefix, org, version, "P")
      sibling = insert_pattern(prefix, org, sibling_version, "P")
      foreign = insert_pattern(prefix, org_b, version_b, "P")

      [first_a, middle_b, last_a] =
        for {stop, position} <- [{"A", 1}, {"B", 2}, {"A", 3}],
            do: insert_occurrence(prefix, pattern, org, version, stop, position)

      sibling_occurrence = insert_occurrence(prefix, sibling, org, sibling_version, "Z", 1)
      foreign_occurrence = insert_occurrence(prefix, foreign, org_b, version_b, "Y", 1)

      weekday = insert_timing(prefix, pattern, org, version, "Weekday", "key-weekday")
      weekend = insert_timing(prefix, pattern, org, version, "Weekend", "key-weekend")
      sibling_timing = insert_timing(prefix, sibling, org, sibling_version, "Weekday", nil)

      timing_rows =
        for timing <- [weekday, weekend],
            occurrence <- [first_a, middle_b, last_a],
            do: {insert_timing_row(prefix, timing, occurrence), timing, occurrence}

      segment = insert_alignment_segment(prefix, last_a)

      child = insert_pattern(prefix, org, version, "P-CHILD", pattern)

      Migrator.up(Repo, @migration_version, Migration, prefix: prefix, log: false)

      assert natural_ids(prefix, "route_pattern_stops") == %{
               first_a => "P",
               middle_b => "P",
               last_a => "P",
               sibling_occurrence => "P",
               foreign_occurrence => "P"
             }

      assert natural_ids(prefix, "timed_patterns") == %{
               weekday => "P",
               weekend => "P",
               sibling_timing => "P"
             }

      # A visit keeps its own row, position and stop: `A` appears twice and the two
      # visits are still different rows.
      assert occurrence_rows(prefix, pattern_scope(org, version)) == [
               {first_a, "A", 1},
               {middle_b, "B", 2},
               {last_a, "A", 3}
             ]

      assert occurrence_rows(prefix, pattern_scope(org, sibling_version)) == [
               {sibling_occurrence, "Z", 1}
             ]

      # Timing rows still point at the same occurrence and timing rows.
      assert timing_row_links(prefix) ==
               Enum.sort(
                 for {row, timing, occurrence} <- timing_rows, do: {row, timing, occurrence}
               )

      assert alignment_anchor(prefix, segment) == last_a

      # The label reference is the owner's natural ID, and a pattern without an
      # owner stays unlabelled.
      assert label_ids(prefix) == %{child => "P", pattern => nil, sibling => nil, foreign => nil}

      assert [["NO", "NO", "YES"]] = reference_nullability(prefix)
    end

    test "refuses to convert when a row cannot be resolved in its own scope" do
      prefix = setup_prefix()
      org = Ecto.UUID.generate()
      other_org = Ecto.UUID.generate()
      version = Ecto.UUID.generate()
      other_version = Ecto.UUID.generate()

      pattern = insert_pattern(prefix, org, version, "P")
      healthy = insert_occurrence(prefix, pattern, org, version, "A", 1)

      # An occurrence naming a pattern row of another organization cannot be
      # translated without guessing that organization's pattern.
      foreign = insert_pattern(prefix, other_org, other_version, "P")
      drop_owner_keys(prefix)
      orphan = insert_occurrence(prefix, foreign, org, version, "B", 2)

      error =
        assert_raise Postgrex.Error, ~r/could not be resolved to a scoped route pattern/, fn ->
          Migrator.up(Repo, @migration_version, Migration, prefix: prefix, log: false)
        end

      # The diagnostic names the unresolved row and its fields, not healthy rows.
      assert error.postgres.message =~ "route_pattern_stops id=#{orphan}"
      assert error.postgres.message =~ "organization_id=#{org}"
      assert error.postgres.message =~ "route_pattern_id=#{foreign}"
      refute error.postgres.message =~ healthy

      # Nothing was converted.
      assert %{rows: [[type]]} =
               SQL.query!(
                 Repo,
                 """
                 SELECT data_type FROM information_schema.columns
                 WHERE table_schema = $1 AND table_name = 'route_pattern_stops'
                   AND column_name = 'route_pattern_id'
                 """,
                 [prefix]
               )

      assert type == "uuid"
    end

    test "refuses an unresolved label owner" do
      prefix = setup_prefix()
      org = Ecto.UUID.generate()
      version = Ecto.UUID.generate()
      other_version = Ecto.UUID.generate()

      foreign_owner = insert_pattern(prefix, org, other_version, "OWNER")
      drop_owner_keys(prefix)
      labelled = insert_pattern(prefix, org, version, "CHILD", foreign_owner)

      error =
        assert_raise Postgrex.Error, ~r/label references could not be resolved/, fn ->
          Migrator.up(Repo, @migration_version, Migration, prefix: prefix, log: false)
        end

      assert error.postgres.message =~ "route_patterns id=#{labelled}"
      assert error.postgres.message =~ "label_pattern_id=#{foreign_owner}"
    end
  end

  describe "down/0" do
    test "restores row UUID references when the scoped parents still exist" do
      prefix = setup_prefix()
      org = Ecto.UUID.generate()
      version = Ecto.UUID.generate()
      other_version = Ecto.UUID.generate()

      pattern = insert_pattern(prefix, org, version, "P")
      _sibling = insert_pattern(prefix, org, other_version, "P")
      occurrence = insert_occurrence(prefix, pattern, org, version, "A", 1)
      timing = insert_timing(prefix, pattern, org, version, "Weekday", nil)
      child = insert_pattern(prefix, org, version, "P-CHILD", pattern)

      Migrator.up(Repo, @migration_version, Migration, prefix: prefix, log: false)
      Migrator.down(Repo, @migration_version, Migration, prefix: prefix, log: false)

      assert uuid_reference(prefix, "route_pattern_stops", occurrence) == pattern
      assert uuid_reference(prefix, "timed_patterns", timing) == pattern
      assert label_reference(prefix, child) == pattern
    end

    test "refuses to roll back when a scoped parent is missing" do
      prefix = setup_prefix()
      org = Ecto.UUID.generate()
      version = Ecto.UUID.generate()

      pattern = insert_pattern(prefix, org, version, "P")
      occurrence = insert_occurrence(prefix, pattern, org, version, "A", 1)

      Migrator.up(Repo, @migration_version, Migration, prefix: prefix, log: false)

      SQL.query!(
        Repo,
        "ALTER TABLE #{q(prefix)}.route_pattern_stops DROP CONSTRAINT route_pattern_stops_route_patterns_owner_fkey",
        []
      )

      SQL.query!(Repo, "DELETE FROM #{q(prefix)}.route_patterns WHERE id = '#{pattern}'", [])

      assert_raise Postgrex.Error, ~r/cannot be restored to row UUIDs/, fn ->
        Migrator.down(Repo, @migration_version, Migration, prefix: prefix, log: false)
      end

      assert natural_ids(prefix, "route_pattern_stops") == %{occurrence => "P"}
    end
  end

  describe "converted schema" do
    setup do
      prefix = setup_prefix()
      org = Ecto.UUID.generate()
      version = Ecto.UUID.generate()
      other_version = Ecto.UUID.generate()

      pattern = insert_pattern(prefix, org, version, "P")
      sibling = insert_pattern(prefix, org, other_version, "P")
      occurrence = insert_occurrence(prefix, pattern, org, version, "A", 1)
      timing = insert_timing(prefix, pattern, org, version, "Weekday", "key")
      child = insert_pattern(prefix, org, version, "P-CHILD", pattern)

      Migrator.up(Repo, @migration_version, Migration, prefix: prefix, log: false)

      {:ok,
       prefix: prefix,
       org: org,
       version: version,
       other_version: other_version,
       pattern: pattern,
       sibling: sibling,
       occurrence: occurrence,
       timing: timing,
       child: child}
    end

    test "a pattern ID rename follows into occurrences, timings and labels", context do
      SQL.query!(
        Repo,
        "UPDATE #{q(context.prefix)}.route_patterns SET route_pattern_id = 'P2' WHERE id = '#{context.pattern}'",
        []
      )

      assert natural_ids(context.prefix, "route_pattern_stops") == %{context.occurrence => "P2"}
      assert natural_ids(context.prefix, "timed_patterns") == %{context.timing => "P2"}
      assert label_ids(context.prefix)[context.child] == "P2"

      # The sibling version's `P` is untouched.
      assert label_ids(context.prefix)[context.sibling] == nil
    end

    test "deleting a pattern removes its occurrences and timings but not a label owner in use",
         context do
      assert_raise Postgrex.Error, ~r/route_patterns_label_pattern_id_fkey/, fn ->
        SQL.query!(
          Repo,
          "DELETE FROM #{q(context.prefix)}.route_patterns WHERE id = '#{context.pattern}'",
          []
        )
      end

      SQL.query!(
        Repo,
        "UPDATE #{q(context.prefix)}.route_patterns SET label_pattern_id = NULL WHERE id = '#{context.child}'",
        []
      )

      SQL.query!(
        Repo,
        "DELETE FROM #{q(context.prefix)}.route_patterns WHERE id = '#{context.pattern}'",
        []
      )

      assert natural_ids(context.prefix, "route_pattern_stops") == %{}
      assert natural_ids(context.prefix, "timed_patterns") == %{}
    end

    test "a pattern ID that exists only in another scope is not a parent", context do
      lonely =
        insert_pattern(context.prefix, context.org, context.other_version, "ONLY-ELSEWHERE")

      assert lonely

      assert_scope_refused(fn ->
        insert_occurrence(
          context.prefix,
          "ONLY-ELSEWHERE",
          context.org,
          context.version,
          "B",
          2
        )
      end)

      assert_scope_refused(fn ->
        insert_timing(context.prefix, "ONLY-ELSEWHERE", context.org, context.version, "T", nil)
      end)
    end

    test "position, timing name and derivation key are unique per pattern scope", context do
      assert_raise Postgrex.Error, ~r/route_pattern_stops_route_pattern_id_position_index/, fn ->
        insert_occurrence(context.prefix, "P", context.org, context.version, "C", 1)
      end

      assert_raise Postgrex.Error, ~r/timed_patterns_route_pattern_id_lower_name_index/, fn ->
        insert_timing(context.prefix, "P", context.org, context.version, "WEEKDAY", nil)
      end

      assert_raise Postgrex.Error, ~r/timed_patterns_route_pattern_id_derivation_key_index/, fn ->
        insert_timing(context.prefix, "P", context.org, context.version, "Other", "key")
      end

      # The sibling version's `P` may hold the same position, name and key.
      insert_occurrence(context.prefix, "P", context.org, context.other_version, "A", 1)
      insert_timing(context.prefix, "P", context.org, context.other_version, "Weekday", "key")
    end

    test "a pattern cannot be its own label owner", context do
      assert_raise Postgrex.Error, ~r/route_patterns_label_not_self/, fn ->
        SQL.query!(
          Repo,
          "UPDATE #{q(context.prefix)}.route_patterns SET label_pattern_id = 'P' WHERE id = '#{context.pattern}'",
          []
        )
      end
    end
  end

  defp assert_scope_refused(fun) do
    assert_raise Postgrex.Error, ~r/route_patterns_owner_fkey/, fun
  end

  defp q(prefix), do: ~s|"#{prefix}"|

  defp pattern_scope(org, version), do: {org, version}

  defp reference_nullability(prefix) do
    %{rows: rows} =
      SQL.query!(
        Repo,
        """
        SELECT
          max(CASE WHEN table_name = 'route_pattern_stops' AND column_name = 'route_pattern_id' THEN is_nullable END),
          max(CASE WHEN table_name = 'timed_patterns' AND column_name = 'route_pattern_id' THEN is_nullable END),
          max(CASE WHEN table_name = 'route_patterns' AND column_name = 'label_pattern_id' THEN is_nullable END)
        FROM information_schema.columns
        WHERE table_schema = $1
        """,
        [prefix]
      )

    rows
  end

  defp natural_ids(prefix, table) do
    %{rows: rows} =
      SQL.query!(Repo, "SELECT id::text, route_pattern_id::text FROM #{q(prefix)}.#{table}", [])

    Map.new(rows, fn [id, value] -> {id, value} end)
  end

  defp label_ids(prefix) do
    %{rows: rows} =
      SQL.query!(
        Repo,
        "SELECT id::text, label_pattern_id::text FROM #{q(prefix)}.route_patterns",
        []
      )

    Map.new(rows, fn [id, value] -> {id, value} end)
  end

  defp occurrence_rows(prefix, {org, version}) do
    %{rows: rows} =
      SQL.query!(
        Repo,
        """
        SELECT id::text, stop_id, position FROM #{q(prefix)}.route_pattern_stops
        WHERE organization_id = '#{org}' AND gtfs_version_id = '#{version}'
        ORDER BY position
        """,
        []
      )

    Enum.map(rows, fn [id, stop_id, position] -> {id, stop_id, position} end)
  end

  defp timing_row_links(prefix) do
    %{rows: rows} =
      SQL.query!(
        Repo,
        "SELECT id::text, timed_pattern_id::text, route_pattern_stop_id::text FROM #{q(prefix)}.timed_pattern_stops",
        []
      )

    rows |> Enum.map(&List.to_tuple/1) |> Enum.sort()
  end

  defp alignment_anchor(prefix, segment) do
    %{rows: [[anchor]]} =
      SQL.query!(
        Repo,
        "SELECT from_occurrence_id::text FROM #{q(prefix)}.alignment_segments WHERE id = '#{segment}'",
        []
      )

    anchor
  end

  defp uuid_reference(prefix, table, id) do
    %{rows: [[value]]} =
      SQL.query!(
        Repo,
        "SELECT route_pattern_id::text FROM #{q(prefix)}.#{table} WHERE id = '#{id}'",
        []
      )

    value
  end

  defp label_reference(prefix, id) do
    %{rows: [[value]]} =
      SQL.query!(
        Repo,
        "SELECT label_pattern_id::text FROM #{q(prefix)}.route_patterns WHERE id = '#{id}'",
        []
      )

    value
  end

  defp drop_owner_keys(prefix) do
    for statement <- [
          "ALTER TABLE #{q(prefix)}.route_pattern_stops DROP CONSTRAINT route_pattern_stops_route_pattern_id_fkey",
          "ALTER TABLE #{q(prefix)}.route_pattern_stops DROP CONSTRAINT route_pattern_stops_route_patterns_owner_fkey",
          "ALTER TABLE #{q(prefix)}.route_patterns DROP CONSTRAINT route_patterns_label_pattern_id_fkey"
        ] do
      SQL.query!(Repo, statement, [])
    end
  end

  defp setup_prefix do
    prefix = "test_convert_pattern_#{System.unique_integer([:positive])}"
    SQL.query!(Repo, ~s|CREATE SCHEMA "#{prefix}"|, [])

    on_exit(fn -> SQL.query!(Repo, ~s|DROP SCHEMA IF EXISTS "#{prefix}" CASCADE|, []) end)

    for statement <- [
          """
          CREATE TABLE #{q(prefix)}.route_patterns (
            id uuid PRIMARY KEY,
            organization_id uuid NOT NULL,
            gtfs_version_id uuid NOT NULL,
            route_pattern_id varchar(255) NOT NULL,
            route_id varchar(255) NOT NULL,
            direction_id integer NOT NULL,
            label_pattern_id uuid,
            inserted_at timestamp(6) NOT NULL,
            updated_at timestamp(6) NOT NULL
          )
          """,
          """
          CREATE UNIQUE INDEX route_patterns_id_organization_id_gtfs_version_id_index
          ON #{q(prefix)}.route_patterns (id, organization_id, gtfs_version_id)
          """,
          """
          CREATE UNIQUE INDEX route_patterns_organization_id_gtfs_version_id_route_pattern_id
          ON #{q(prefix)}.route_patterns (organization_id, gtfs_version_id, route_pattern_id)
          """,
          "CREATE INDEX route_patterns_label_pattern_id_index ON #{q(prefix)}.route_patterns (label_pattern_id)",
          """
          ALTER TABLE #{q(prefix)}.route_patterns
            ADD CONSTRAINT route_patterns_label_pattern_id_fkey
            FOREIGN KEY (label_pattern_id) REFERENCES #{q(prefix)}.route_patterns (id)
            ON DELETE RESTRICT,
            ADD CONSTRAINT route_patterns_label_not_self
            CHECK (label_pattern_id IS NULL OR label_pattern_id <> id)
          """,
          """
          CREATE TABLE #{q(prefix)}.route_pattern_stops (
            id uuid PRIMARY KEY,
            route_pattern_id uuid NOT NULL
              REFERENCES #{q(prefix)}.route_patterns (id) ON DELETE CASCADE,
            organization_id uuid NOT NULL,
            gtfs_version_id uuid NOT NULL,
            stop_id varchar(255) NOT NULL,
            position integer NOT NULL,
            inserted_at timestamp(6) NOT NULL,
            updated_at timestamp(6) NOT NULL
          )
          """,
          """
          CREATE UNIQUE INDEX route_pattern_stops_id_organization_id_gtfs_version_id_index
          ON #{q(prefix)}.route_pattern_stops (id, organization_id, gtfs_version_id)
          """,
          """
          CREATE UNIQUE INDEX route_pattern_stops_route_pattern_id_position_index
          ON #{q(prefix)}.route_pattern_stops (route_pattern_id, position)
          """,
          """
          CREATE INDEX route_pattern_stops_organization_id_gtfs_version_id_route_patte
          ON #{q(prefix)}.route_pattern_stops (organization_id, gtfs_version_id, route_pattern_id)
          """,
          """
          ALTER TABLE #{q(prefix)}.route_pattern_stops
            ADD CONSTRAINT route_pattern_stops_route_patterns_owner_fkey
            FOREIGN KEY (route_pattern_id, organization_id, gtfs_version_id)
            REFERENCES #{q(prefix)}.route_patterns (id, organization_id, gtfs_version_id)
          """,
          """
          CREATE TABLE #{q(prefix)}.timed_patterns (
            id uuid PRIMARY KEY,
            route_pattern_id uuid NOT NULL
              REFERENCES #{q(prefix)}.route_patterns (id) ON DELETE CASCADE,
            organization_id uuid NOT NULL,
            gtfs_version_id uuid NOT NULL,
            name varchar(255) NOT NULL,
            derivation_key varchar(255),
            inserted_at timestamp(6) NOT NULL,
            updated_at timestamp(6) NOT NULL
          )
          """,
          """
          CREATE UNIQUE INDEX timed_patterns_route_pattern_id_lower_name_index
          ON #{q(prefix)}.timed_patterns (route_pattern_id, lower(name))
          """,
          """
          CREATE UNIQUE INDEX timed_patterns_route_pattern_id_derivation_key_index
          ON #{q(prefix)}.timed_patterns (route_pattern_id, derivation_key)
          WHERE derivation_key IS NOT NULL
          """,
          """
          CREATE INDEX timed_patterns_organization_id_gtfs_version_id_route_pattern_id
          ON #{q(prefix)}.timed_patterns (organization_id, gtfs_version_id, route_pattern_id)
          """,
          """
          ALTER TABLE #{q(prefix)}.timed_patterns
            ADD CONSTRAINT timed_patterns_route_patterns_owner_fkey
            FOREIGN KEY (route_pattern_id, organization_id, gtfs_version_id)
            REFERENCES #{q(prefix)}.route_patterns (id, organization_id, gtfs_version_id)
          """,
          """
          CREATE TABLE #{q(prefix)}.timed_pattern_stops (
            id uuid PRIMARY KEY,
            timed_pattern_id uuid NOT NULL
              REFERENCES #{q(prefix)}.timed_patterns (id) ON DELETE CASCADE,
            route_pattern_stop_id uuid NOT NULL
              REFERENCES #{q(prefix)}.route_pattern_stops (id) ON DELETE RESTRICT,
            arrival_offset integer,
            departure_offset integer,
            inserted_at timestamp(6) NOT NULL,
            updated_at timestamp(6) NOT NULL
          )
          """,
          """
          CREATE TABLE #{q(prefix)}.alignment_segments (
            id uuid PRIMARY KEY,
            from_occurrence_id uuid NOT NULL
              REFERENCES #{q(prefix)}.route_pattern_stops (id) ON DELETE CASCADE
          )
          """
        ] do
      SQL.query!(Repo, statement, [])
    end

    prefix
  end

  # A pattern is addressed by its row UUID before the conversion and by its GTFS
  # ID afterwards, so the insert helpers take either reference.
  defp insert_pattern(prefix, org, version, route_pattern_id, label_owner \\ nil) do
    id = Ecto.UUID.generate()

    SQL.query!(
      Repo,
      """
      INSERT INTO #{q(prefix)}.route_patterns
        (id, organization_id, gtfs_version_id, route_pattern_id, route_id, direction_id,
         label_pattern_id, inserted_at, updated_at)
      VALUES (#{uuid(id)}, #{uuid(org)}, #{uuid(version)}, $1, 'R1', 0,
              #{reference_literal(label_owner)}, now(), now())
      """,
      [route_pattern_id]
    )

    id
  end

  defp insert_occurrence(prefix, pattern, org, version, stop_id, position) do
    id = Ecto.UUID.generate()

    SQL.query!(
      Repo,
      """
      INSERT INTO #{q(prefix)}.route_pattern_stops
        (id, route_pattern_id, organization_id, gtfs_version_id, stop_id, position,
         inserted_at, updated_at)
      VALUES (#{uuid(id)}, #{reference_literal(pattern)}, #{uuid(org)}, #{uuid(version)},
              $1, $2, now(), now())
      """,
      [stop_id, position]
    )

    id
  end

  defp insert_timing(prefix, pattern, org, version, name, derivation_key) do
    id = Ecto.UUID.generate()

    SQL.query!(
      Repo,
      """
      INSERT INTO #{q(prefix)}.timed_patterns
        (id, route_pattern_id, organization_id, gtfs_version_id, name, derivation_key,
         inserted_at, updated_at)
      VALUES (#{uuid(id)}, #{reference_literal(pattern)}, #{uuid(org)}, #{uuid(version)},
              $1, $2, now(), now())
      """,
      [name, derivation_key]
    )

    id
  end

  defp insert_timing_row(prefix, timing, occurrence) do
    id = Ecto.UUID.generate()

    SQL.query!(
      Repo,
      """
      INSERT INTO #{q(prefix)}.timed_pattern_stops
        (id, timed_pattern_id, route_pattern_stop_id, arrival_offset, departure_offset,
         inserted_at, updated_at)
      VALUES (#{uuid(id)}, #{uuid(timing)}, #{uuid(occurrence)}, 0, 0, now(), now())
      """,
      []
    )

    id
  end

  defp insert_alignment_segment(prefix, occurrence) do
    id = Ecto.UUID.generate()

    SQL.query!(
      Repo,
      "INSERT INTO #{q(prefix)}.alignment_segments (id, from_occurrence_id) VALUES (#{uuid(id)}, #{uuid(occurrence)})",
      []
    )

    id
  end

  defp uuid(value), do: ~s|'#{value}'::uuid|

  defp reference_literal(nil), do: "NULL"

  defp reference_literal(value) when is_binary(value) do
    case Ecto.UUID.cast(value) do
      {:ok, _} -> ~s|'#{value}'::uuid|
      :error -> ~s|'#{value}'|
    end
  end
end
