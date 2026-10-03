defmodule GtfsPlanner.Repo.Migrations.ConvertStopLevelReferencesTest do
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL
  alias Ecto.Adapters.SQL.Sandbox
  alias Ecto.Migrator

  alias GtfsPlanner.Repo

  @migration_path Path.expand(
                    "../../../../priv/repo/migrations/20261003025820_convert_stop_level_references_to_gtfs_ids.exs",
                    __DIR__
                  )
  Code.require_file(@migration_path)

  @migration_version @migration_path
                     |> Path.basename()
                     |> String.split("_", parts: 2)
                     |> hd()
                     |> String.to_integer()

  alias GtfsPlanner.Repo.Migrations.ConvertStopLevelReferencesToGtfsIds, as: Migration

  @image_bytes :binary.copy(<<0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A>>, 512)
  @foreign_image_bytes :binary.copy(<<0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0B>>, 256)

  setup_all do
    Sandbox.mode(Repo, :auto)
    on_exit(fn -> Sandbox.mode(Repo, :manual) end)
    :ok
  end

  describe "up/0" do
    test "replaces row UUID references with scoped GTFS identifiers and preserves the rest" do
      prefix = setup_prefix()
      org_a = Ecto.UUID.generate()
      org_b = Ecto.UUID.generate()
      version_a = Ecto.UUID.generate()
      version_b = Ecto.UUID.generate()

      # Two scoped stations that share the natural ID "S1", plus a third
      # station whose only row lives in another version.
      s1_a = insert_stop(prefix, org_a, version_a, "S1")
      s1_b = insert_stop(prefix, org_b, version_b, "S1")
      _s1_sibling_version = insert_stop(prefix, org_a, version_b, "S1")
      l1_a = insert_level(prefix, org_a, version_a, "L1")
      l1_b = insert_level(prefix, org_b, version_b, "L1")

      floorplan_id = Ecto.UUID.generate()

      converted =
        insert_stop_level(prefix, floorplan_id, org_a, version_a, s1_a, l1_a, %{
          diagram_filename: "gtfs/plans/S1-L1.png",
          scale_point_a: %{"x" => 1.0, "y" => 2.0},
          scale_point_b: %{"x" => 3.0, "y" => 4.0},
          scale_distance_meters: "12.5",
          scale_meters_per_unit: "0.25",
          floorplan_center_lat: 40.7128,
          floorplan_center_lon: -74.006,
          floorplan_scale_mpp: 0.5,
          floorplan_rotation_deg: 15.0
        })

      # A floorplan attached to the foreign organization keeps its own row and
      # converts against its own parents.
      foreign_id = Ecto.UUID.generate()

      insert_stop_level(prefix, foreign_id, org_b, version_b, s1_b, l1_b, %{
        diagram_filename: "gtfs/plans/S1-L1-foreign.png"
      })

      # Owned diagram files stand in for the retained image bytes; the migration
      # changes references only, so each floorplan keeps pointing at its own file.
      root =
        Path.join(System.tmp_dir!(), "convert_stop_level_#{System.unique_integer([:positive])}")

      File.mkdir_p!(root)
      on_exit(fn -> File.rm_rf!(root) end)

      diagram_path = Path.join(root, "S1-L1.png")
      foreign_diagram_path = Path.join(root, "S1-L1-foreign.png")
      File.write!(diagram_path, @image_bytes)
      File.write!(foreign_diagram_path, @foreign_image_bytes)

      Migrator.up(Repo, @migration_version, Migration, prefix: prefix, log: false)

      assert stop_level(prefix, converted)["stop_id"] == "S1"
      assert stop_level(prefix, converted)["level_id"] == "L1"

      foreign = stop_level(prefix, foreign_id)
      assert foreign["stop_id"] == "S1"
      assert foreign["level_id"] == "L1"
      assert foreign["diagram_filename"] == "gtfs/plans/S1-L1-foreign.png"

      assert File.read!(diagram_path) == @image_bytes
      assert File.read!(foreign_diagram_path) == @foreign_image_bytes

      assert Path.basename(diagram_path) ==
               Path.basename(stop_level(prefix, converted)["diagram_filename"])

      assert Path.basename(foreign_diagram_path) == Path.basename(foreign["diagram_filename"])

      assert [["NO", "NO"]] = reference_nullability(prefix)

      # Identity, diagram, geometry and scale data survive the column swap.
      preserved = stop_level(prefix, converted)

      assert Ecto.UUID.load!(preserved["id"]) == floorplan_id
      assert preserved["diagram_filename"] == "gtfs/plans/S1-L1.png"
      assert preserved["scale_point_a"] == %{"x" => 1.0, "y" => 2.0}
      assert preserved["scale_point_b"] == %{"x" => 3.0, "y" => 4.0}
      assert Decimal.equal?(Decimal.new(preserved["scale_distance_meters"]), "12.5")
      assert Decimal.equal?(Decimal.new(preserved["scale_meters_per_unit"]), "0.25")
      assert preserved["floorplan_center_lat"] == 40.7128
      assert preserved["floorplan_center_lon"] == -74.006
      assert preserved["floorplan_scale_mpp"] == 0.5
      assert preserved["floorplan_rotation_deg"] == 15.0
      assert Ecto.UUID.load!(preserved["organization_id"]) == org_a
      assert Ecto.UUID.load!(preserved["gtfs_version_id"]) == version_a
    end

    test "keeps journal attachment handles attached to the same floorplan row" do
      prefix = setup_prefix()
      org = Ecto.UUID.generate()
      version = Ecto.UUID.generate()
      stop = insert_stop(prefix, org, version, "S1")
      level = insert_level(prefix, org, version, "L1")
      floorplan_id = Ecto.UUID.generate()

      insert_stop_level(prefix, floorplan_id, org, version, stop, level, %{
        diagram_filename: "gtfs/plans/S1-L1.png"
      })

      pin_id = Ecto.UUID.generate()

      SQL.query!(
        Repo,
        """
        INSERT INTO "#{prefix}".journal_entries
          (id, station_id, stop_level_id, diagram_x, diagram_y, inserted_at, updated_at)
        VALUES ('#{pin_id}', '#{stop}', '#{floorplan_id}', 10.0, 20.0, now(), now())
        """,
        []
      )

      Migrator.up(Repo, @migration_version, Migration, prefix: prefix, log: false)

      assert %{rows: [[diagram_x, diagram_y, attached]]} =
               SQL.query!(
                 Repo,
                 """
                 SELECT diagram_x, diagram_y, (stop_level_id = '#{floorplan_id}') AS attached
                 FROM "#{prefix}".journal_entries WHERE id = '#{pin_id}'
                 """,
                 []
               )

      assert diagram_x == 10.0
      assert diagram_y == 20.0
      assert attached == true
    end

    test "refuses to convert when a floorplan cannot be resolved in its own scope" do
      prefix = setup_prefix()
      org = Ecto.UUID.generate()
      version = Ecto.UUID.generate()
      stop = insert_stop(prefix, org, version, "S1")
      level = insert_level(prefix, org, version, "L1")
      floorplan_id = Ecto.UUID.generate()

      insert_stop_level(prefix, floorplan_id, org, version, stop, level, %{})

      # A floorplan naming a stop row from another organization cannot be
      # translated without guessing that organization's station.
      SQL.query!(
        Repo,
        "ALTER TABLE #{q(prefix)}.stop_levels DROP CONSTRAINT stop_levels_stop_id_fkey",
        []
      )

      SQL.query!(
        Repo,
        "ALTER TABLE #{q(prefix)}.stop_levels DROP CONSTRAINT stop_levels_stops_owner_fkey",
        []
      )

      orphan_id = Ecto.UUID.generate()

      insert_stop_level(prefix, orphan_id, org, version, Ecto.UUID.generate(), level, %{})

      error =
        assert_raise Postgrex.Error, ~r/could not be resolved to a scoped stop or level/, fn ->
          Migrator.up(Repo, @migration_version, Migration, prefix: prefix, log: false)
        end

      # The diagnostic names the unresolved row and its fields, not healthy rows.
      assert error.postgres.message =~ "stop_levels id=#{orphan_id}"
      assert error.postgres.message =~ "organization_id=#{org}"
      refute error.postgres.message =~ floorplan_id

      # Nothing was converted.
      assert %{rows: [[row_stop_id]]} =
               SQL.query!(
                 Repo,
                 "SELECT stop_id::text FROM #{q(prefix)}.stop_levels WHERE id = '#{floorplan_id}'",
                 []
               )

      assert row_stop_id == stop
    end
  end

  describe "down/0" do
    test "restores row UUID references when the scoped parents still exist" do
      prefix = setup_prefix()
      org = Ecto.UUID.generate()
      version = Ecto.UUID.generate()
      stop = insert_stop(prefix, org, version, "S1")
      level = insert_level(prefix, org, version, "L1")
      floorplan_id = Ecto.UUID.generate()

      insert_stop_level(prefix, floorplan_id, org, version, stop, level, %{
        diagram_filename: "gtfs/plans/S1-L1.png"
      })

      Migrator.up(Repo, @migration_version, Migration, prefix: prefix, log: false)
      assert stop_level(prefix, floorplan_id)["stop_id"] == "S1"

      Migrator.down(Repo, @migration_version, Migration, prefix: prefix, log: false)

      restored = stop_level(prefix, floorplan_id)
      assert Ecto.UUID.load!(restored["stop_id"]) == stop
      assert Ecto.UUID.load!(restored["level_id"]) == level
      assert Ecto.UUID.load!(restored["id"]) == floorplan_id
      assert restored["diagram_filename"] == "gtfs/plans/S1-L1.png"
    end

    test "refuses to roll back when a scoped parent is missing" do
      prefix = setup_prefix()
      org = Ecto.UUID.generate()
      version = Ecto.UUID.generate()
      stop = insert_stop(prefix, org, version, "S1")
      level = insert_level(prefix, org, version, "L1")
      floorplan_id = Ecto.UUID.generate()

      insert_stop_level(prefix, floorplan_id, org, version, stop, level, %{})

      Migrator.up(Repo, @migration_version, Migration, prefix: prefix, log: false)

      SQL.query!(
        Repo,
        "ALTER TABLE #{q(prefix)}.stop_levels DROP CONSTRAINT stop_levels_stops_owner_fkey",
        []
      )

      SQL.query!(
        Repo,
        "ALTER TABLE #{q(prefix)}.stop_levels DROP CONSTRAINT stop_levels_levels_owner_fkey",
        []
      )

      SQL.query!(Repo, "DELETE FROM #{q(prefix)}.stops WHERE id = '#{stop}'", [])

      assert_raise Postgrex.Error, ~r/cannot be restored to row UUIDs/, fn ->
        Migrator.down(Repo, @migration_version, Migration, prefix: prefix, log: false)
      end

      assert stop_level(prefix, floorplan_id)["stop_id"] == "S1"
    end
  end

  test "renaming a parent level identifier cascades to the stored floorplan reference" do
    prefix = setup_prefix()
    org = Ecto.UUID.generate()
    version = Ecto.UUID.generate()
    stop = insert_stop(prefix, org, version, "S1")
    level = insert_level(prefix, org, version, "L1")
    floorplan_id = Ecto.UUID.generate()

    insert_stop_level(prefix, floorplan_id, org, version, stop, level, %{})

    Migrator.up(Repo, @migration_version, Migration, prefix: prefix, log: false)

    SQL.query!(
      Repo,
      "UPDATE #{q(prefix)}.levels SET level_id = 'L1_RENAMED' WHERE id = '#{level}'",
      []
    )

    assert stop_level(prefix, floorplan_id)["level_id"] == "L1_RENAMED"
  end

  test "deleting a parent stop removes its floorplan as the former reference did" do
    prefix = setup_prefix()
    org = Ecto.UUID.generate()
    version = Ecto.UUID.generate()
    stop = insert_stop(prefix, org, version, "S1")
    level = insert_level(prefix, org, version, "L1")
    floorplan_id = Ecto.UUID.generate()
    insert_stop_level(prefix, floorplan_id, org, version, stop, level, %{})

    Migrator.up(Repo, @migration_version, Migration, prefix: prefix, log: false)

    SQL.query!(Repo, "DELETE FROM #{q(prefix)}.stops WHERE id = '#{stop}'", [])

    assert %{rows: []} =
             SQL.query!(
               Repo,
               "SELECT 1 FROM #{q(prefix)}.stop_levels WHERE id = '#{floorplan_id}'",
               []
             )
  end

  test "a floorplan naming a foreign identifier cannot be inserted under a local scope" do
    prefix = setup_prefix()
    org = Ecto.UUID.generate()
    version = Ecto.UUID.generate()
    insert_stop(prefix, Ecto.UUID.generate(), Ecto.UUID.generate(), "S1")
    insert_level(prefix, Ecto.UUID.generate(), Ecto.UUID.generate(), "L1")

    Migrator.up(Repo, @migration_version, Migration, prefix: prefix, log: false)

    assert_raise Postgrex.Error, ~r/stop_levels_(stops|levels)_owner_fkey/, fn ->
      insert_stop_level(
        prefix,
        Ecto.UUID.generate(),
        org,
        version,
        "S1",
        "L1",
        %{}
      )
    end
  end

  defp q(prefix), do: ~s|"#{prefix}"|

  defp reference_nullability(prefix) do
    %{rows: rows} =
      SQL.query!(
        Repo,
        """
        SELECT
          max(CASE WHEN column_name = 'stop_id' THEN is_nullable END),
          max(CASE WHEN column_name = 'level_id' THEN is_nullable END)
        FROM information_schema.columns
        WHERE table_schema = $1 AND table_name = 'stop_levels'
        """,
        [prefix]
      )

    rows
  end

  defp setup_prefix do
    prefix = "test_convert_stop_level_#{System.unique_integer([:positive])}"
    SQL.query!(Repo, ~s|CREATE SCHEMA "#{prefix}"|, [])

    on_exit(fn -> SQL.query!(Repo, ~s|DROP SCHEMA IF EXISTS "#{prefix}" CASCADE|, []) end)

    SQL.query!(Repo, "CREATE TABLE #{q(prefix)}.organizations (id uuid PRIMARY KEY)", [])
    SQL.query!(Repo, "CREATE TABLE #{q(prefix)}.gtfs_versions (id uuid PRIMARY KEY)", [])

    SQL.query!(
      Repo,
      """
      CREATE TABLE #{q(prefix)}.stops (
        id uuid PRIMARY KEY,
        stop_id varchar(255) NOT NULL,
        organization_id uuid NOT NULL,
        gtfs_version_id uuid NOT NULL
      )
      """,
      []
    )

    SQL.query!(
      Repo,
      """
      CREATE UNIQUE INDEX stops_scoped_stop_id
      ON #{q(prefix)}.stops (organization_id, gtfs_version_id, stop_id)
      """,
      []
    )

    SQL.query!(
      Repo,
      """
      CREATE UNIQUE INDEX stops_scoped_row
      ON #{q(prefix)}.stops (id, organization_id, gtfs_version_id)
      """,
      []
    )

    SQL.query!(
      Repo,
      """
      CREATE TABLE #{q(prefix)}.levels (
        id uuid PRIMARY KEY,
        level_id varchar(255) NOT NULL,
        organization_id uuid NOT NULL,
        gtfs_version_id uuid NOT NULL
      )
      """,
      []
    )

    SQL.query!(
      Repo,
      """
      CREATE UNIQUE INDEX levels_scoped_level_id
      ON #{q(prefix)}.levels (organization_id, gtfs_version_id, level_id)
      """,
      []
    )

    SQL.query!(
      Repo,
      """
      CREATE UNIQUE INDEX levels_scoped_row
      ON #{q(prefix)}.levels (id, organization_id, gtfs_version_id)
      """,
      []
    )

    SQL.query!(
      Repo,
      """
      CREATE TABLE #{q(prefix)}.stop_levels (
        id uuid PRIMARY KEY,
        stop_id uuid NOT NULL REFERENCES #{q(prefix)}.stops(id) ON DELETE CASCADE,
        level_id uuid NOT NULL REFERENCES #{q(prefix)}.levels(id) ON DELETE CASCADE,
        diagram_filename varchar(255),
        scale_point_a jsonb,
        scale_point_b jsonb,
        scale_distance_meters numeric,
        scale_meters_per_unit numeric,
        floorplan_center_lat double precision,
        floorplan_center_lon double precision,
        floorplan_scale_mpp double precision,
        floorplan_rotation_deg double precision,
        organization_id uuid NOT NULL,
        gtfs_version_id uuid NOT NULL,
        inserted_at timestamp(6) NOT NULL,
        updated_at timestamp(6) NOT NULL
      )
      """,
      []
    )

    SQL.query!(
      Repo,
      "CREATE INDEX stop_levels_stop_id_index ON #{q(prefix)}.stop_levels (stop_id)",
      []
    )

    SQL.query!(
      Repo,
      "CREATE INDEX stop_levels_level_id_index ON #{q(prefix)}.stop_levels (level_id)",
      []
    )

    SQL.query!(
      Repo,
      """
      CREATE TABLE #{q(prefix)}.journal_entries (
        id uuid PRIMARY KEY,
        station_id uuid NOT NULL,
        stop_level_id uuid,
        diagram_x double precision,
        diagram_y double precision,
        inserted_at timestamp(6) NOT NULL,
        updated_at timestamp(6) NOT NULL
      )
      """,
      []
    )

    SQL.query!(
      Repo,
      "CREATE INDEX stop_levels_organization_id_gtfs_version_id_index ON #{q(prefix)}.stop_levels (organization_id, gtfs_version_id)",
      []
    )

    SQL.query!(
      Repo,
      """
      ALTER TABLE #{q(prefix)}.stop_levels
      ADD CONSTRAINT stop_levels_stops_owner_fkey
      FOREIGN KEY (stop_id, organization_id, gtfs_version_id)
      REFERENCES #{q(prefix)}.stops (id, organization_id, gtfs_version_id)
      ON DELETE NO ACTION NOT VALID
      """,
      []
    )

    SQL.query!(
      Repo,
      """
      ALTER TABLE #{q(prefix)}.stop_levels
      ADD CONSTRAINT stop_levels_levels_owner_fkey
      FOREIGN KEY (level_id, organization_id, gtfs_version_id)
      REFERENCES #{q(prefix)}.levels (id, organization_id, gtfs_version_id)
      ON DELETE NO ACTION NOT VALID
      """,
      []
    )

    prefix
  end

  defp insert_stop(prefix, organization_id, gtfs_version_id, stop_id) do
    id = Ecto.UUID.generate()

    SQL.query!(
      Repo,
      """
      INSERT INTO #{q(prefix)}.stops (id, stop_id, organization_id, gtfs_version_id)
      VALUES (#{uuid(id)}, $1, #{uuid(organization_id)}, #{uuid(gtfs_version_id)})
      """,
      [stop_id]
    )

    id
  end

  defp insert_level(prefix, organization_id, gtfs_version_id, level_id) do
    id = Ecto.UUID.generate()

    SQL.query!(
      Repo,
      """
      INSERT INTO #{q(prefix)}.levels (id, level_id, organization_id, gtfs_version_id)
      VALUES (#{uuid(id)}, $1, #{uuid(organization_id)}, #{uuid(gtfs_version_id)})
      """,
      [level_id]
    )

    id
  end

  defp insert_stop_level(
         prefix,
         id,
         organization_id,
         gtfs_version_id,
         stop_ref,
         level_ref,
         extra
       ) do
    values =
      [
        uuid(id),
        reference_literal(stop_ref),
        reference_literal(level_ref),
        quote_nullable(Map.get(extra, :diagram_filename)),
        json_literal(Map.get(extra, :scale_point_a)),
        json_literal(Map.get(extra, :scale_point_b)),
        numeric_literal(Map.get(extra, :scale_distance_meters)),
        numeric_literal(Map.get(extra, :scale_meters_per_unit)),
        numeric_literal(Map.get(extra, :floorplan_center_lat)),
        numeric_literal(Map.get(extra, :floorplan_center_lon)),
        numeric_literal(Map.get(extra, :floorplan_scale_mpp)),
        numeric_literal(Map.get(extra, :floorplan_rotation_deg)),
        uuid(organization_id),
        uuid(gtfs_version_id)
      ]
      |> Enum.join(", ")

    SQL.query!(
      Repo,
      """
      INSERT INTO #{q(prefix)}.stop_levels (
        id, stop_id, level_id, diagram_filename, scale_point_a, scale_point_b,
        scale_distance_meters, scale_meters_per_unit, floorplan_center_lat,
        floorplan_center_lon, floorplan_scale_mpp, floorplan_rotation_deg,
        organization_id, gtfs_version_id, inserted_at, updated_at
      ) VALUES (#{values}, now(), now())
      """,
      []
    )

    id
  end

  defp uuid(value), do: ~s|'#{value}'::uuid|

  defp quote_nullable(nil), do: "NULL"
  defp quote_nullable(value), do: ~s|'#{value}'|

  # The same helper writes rows before and after the swap, so a row UUID becomes
  # a uuid literal while a natural identifier stays a string literal.
  defp reference_literal(value) when is_binary(value) do
    case Ecto.UUID.cast(value) do
      {:ok, _} -> ~s|'#{value}'::uuid|
      :error -> ~s|'#{value}'|
    end
  end

  defp numeric_literal(nil), do: "NULL"
  defp numeric_literal(value), do: to_string(value)

  defp json_literal(nil), do: "NULL"
  defp json_literal(map), do: ~s|'#{JSON.encode!(map)}'::jsonb|

  defp stop_level(prefix, id) do
    %{columns: columns, rows: [values]} =
      SQL.query!(Repo, "SELECT * FROM #{q(prefix)}.stop_levels WHERE id = '#{id}'", [])

    Enum.zip(columns, values) |> Map.new()
  end
end
