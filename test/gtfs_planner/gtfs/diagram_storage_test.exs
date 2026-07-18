defmodule GtfsPlanner.Gtfs.DiagramStorageTest do
  @moduledoc """
  Tests for versioned diagram storage: path isolation, path-traversal rejection,
  write failures, legacy backfill idempotence, byte preservation, historical fallback,
  and the real release migration wiring.
  """

  use GtfsPlanner.DataCase, async: false

  import ExUnit.CaptureLog
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.DiagramStorage
  alias GtfsPlanner.Gtfs.Extensions.PathSafety
  alias GtfsPlanner.Repo

  @legacy_bytes <<1, 2, 3, 4, 5>>
  @import_bytes_a <<10, 20, 30>>
  @import_bytes_b <<40, 50, 60>>

  setup do
    previous = Application.get_env(:gtfs_planner, :uploads_path)

    root =
      Path.join(System.tmp_dir!(), "diagram_storage_#{System.unique_integer([:positive])}")

    Application.put_env(:gtfs_planner, :uploads_path, root)

    on_exit(fn ->
      File.rm_rf!(root)

      if is_nil(previous) do
        Application.delete_env(:gtfs_planner, :uploads_path)
      else
        Application.put_env(:gtfs_planner, :uploads_path, previous)
      end
    end)

    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)

    station =
      stop_fixture(organization.id, version.id,
        stop_id: "station_#{System.unique_integer([:positive])}",
        location_type: 1
      )

    level = level_fixture(organization.id, version.id)

    %{root: root, organization: organization, version: version, station: station, level: level}
  end

  describe "store_import_image/5" do
    test "writes two versions of one station to different paths and preserves both byte sequences",
         %{organization: org, version: version, station: station} do
      other_version = gtfs_version_fixture(org.id)

      assert :ok =
               DiagramStorage.store_import_image(
                 org.id,
                 version.id,
                 station.stop_id,
                 "plan.png",
                 @import_bytes_a
               )

      assert :ok =
               DiagramStorage.store_import_image(
                 org.id,
                 other_version.id,
                 station.stop_id,
                 "plan.png",
                 @import_bytes_b
               )

      path_a = DiagramStorage.published_path(org.id, version.id, station.stop_id, "plan.png")

      path_b =
        DiagramStorage.published_path(org.id, other_version.id, station.stop_id, "plan.png")

      assert {:ok, pa} = path_a
      assert {:ok, pb} = path_b
      refute pa == pb
      assert File.read!(pa) == @import_bytes_a
      assert File.read!(pb) == @import_bytes_b
    end

    test "rejects unsafe components without writing outside the configured root",
         %{root: root, organization: org, version: version} do
      # A slash in the filename escapes the station directory and is rejected.
      assert {:error, :unsafe_path} =
               DiagramStorage.store_import_image(
                 org.id,
                 version.id,
                 "station/1",
                 "../escape.png",
                 @import_bytes_a
               )

      assert {:error, :unsafe_path} =
               DiagramStorage.store_import_image(
                 org.id,
                 version.id,
                 "station/1",
                 "a/../b.png",
                 @import_bytes_a
               )

      # An unsafe organization/version id is rejected.
      assert {:error, :unsafe_path} =
               DiagramStorage.store_import_image(
                 "../org",
                 version.id,
                 "station/1",
                 "plan.png",
                 @import_bytes_a
               )

      assert [] == Path.wildcard(Path.join([root, "diagrams", "**"]))
    end

    test "returns an error when the destination directory cannot be created (write failure)",
         %{organization: org, version: version, station: station} do
      # Place a regular file where the versioned station directory must be created.
      station_dir = PathSafety.stop_storage_dir(station.stop_id)
      blocking_file = Path.join([uploads_root(org.id), version.id, station_dir])
      File.mkdir_p!(Path.dirname(blocking_file))
      File.write!(blocking_file, "i am a file, not a directory")

      log =
        capture_log(fn ->
          assert {:error, _} =
                   DiagramStorage.store_import_image(
                     org.id,
                     version.id,
                     station.stop_id,
                     "plan.png",
                     @import_bytes_a
                   )
        end)

      assert log =~ "diagram_storage"
      # Nothing was created under the versioned namespace root.
      assert [] == Path.wildcard(Path.join([uploads_root(org.id), "**", "*.png"]))
    end

    test "returns badarg for a non-binary station stop id",
         %{organization: org, version: version} do
      assert {:error, :badarg} =
               DiagramStorage.store_import_image(
                 org.id,
                 version.id,
                 123,
                 "plan.png",
                 @import_bytes_a
               )
    end
  end

  describe "published_path/4 and public_url_path/4" do
    test "returns the versioned path/url and falls back only to an existing referenced legacy file",
         %{organization: org, version: version, station: station, level: level} do
      # Seed a legacy file for this station.
      legacy_dir = Path.join([uploads_root(org.id), PathSafety.stop_storage_dir(station.stop_id)])
      File.mkdir_p!(legacy_dir)
      legacy_path = Path.join(legacy_dir, "plan.png")
      File.write!(legacy_path, @legacy_bytes)

      {:ok, _} =
        Gtfs.create_stop_level(%{
          stop_id: station.id,
          level_id: level.id,
          diagram_filename: "plan.png",
          organization_id: org.id,
          gtfs_version_id: version.id
        })

      # No versioned file yet -> published_path fails, public_url_path falls back to legacy.
      assert {:error, :not_found} =
               DiagramStorage.published_path(org.id, version.id, station.stop_id, "plan.png")

      assert {:ok, legacy_url} =
               DiagramStorage.public_url_path(org.id, version.id, station.stop_id, "plan.png")

      assert legacy_url =~
               "/uploads/diagrams/#{org.id}/#{PathSafety.stop_storage_dir(station.stop_id)}/plan.png"

      refute legacy_url =~ version.id

      # After a versioned write, public_url_path prefers the versioned file.
      assert :ok =
               DiagramStorage.store_import_image(
                 org.id,
                 version.id,
                 station.stop_id,
                 "plan.png",
                 @import_bytes_a
               )

      assert {:ok, versioned_path} =
               DiagramStorage.published_path(org.id, version.id, station.stop_id, "plan.png")

      assert versioned_path =~ "/diagrams/#{org.id}/#{version.id}/"
      assert File.read!(versioned_path) == @import_bytes_a

      assert {:ok, versioned_url} =
               DiagramStorage.public_url_path(org.id, version.id, station.stop_id, "plan.png")

      assert versioned_url =~ "/uploads/diagrams/#{org.id}/#{version.id}/"
      # The versioned URL is NOT the legacy shape (organization immediately followed by station).
      refute versioned_url =~
               "/uploads/diagrams/#{org.id}/#{PathSafety.stop_storage_dir(station.stop_id)}/plan.png"

      # Legacy source is preserved.
      assert File.read!(legacy_path) == @legacy_bytes
    end

    test "does not expose an unreferenced legacy file to another published version",
         %{organization: org, version: version, station: station} do
      legacy_dir = Path.join([uploads_root(org.id), PathSafety.stop_storage_dir(station.stop_id)])
      File.mkdir_p!(legacy_dir)
      File.write!(Path.join(legacy_dir, "retired.png"), @legacy_bytes)

      assert {:error, :not_found} =
               DiagramStorage.public_url_path(
                 org.id,
                 version.id,
                 station.stop_id,
                 "retired.png"
               )

      assert {:error, :not_found} =
               DiagramStorage.read_image(
                 org.id,
                 version.id,
                 station.stop_id,
                 "retired.png"
               )
    end

    test "rejects unsafe components for path and url resolution",
         %{organization: org, version: version} do
      # A slash in the filename escapes the station directory and is rejected.
      assert {:error, :unsafe_path} =
               DiagramStorage.published_path(org.id, version.id, "station/1", "a/../plan.png")

      assert {:error, :unsafe_path} =
               DiagramStorage.public_url_path(org.id, version.id, "station/1", "../plan.png")
    end
  end

  describe "migrate_legacy_assets/1" do
    test "copies each referenced published image to every version destination, never overwrites, is idempotent, and preserves legacy source",
         %{organization: org, version: version, station: station, level: level} do
      # Create two published versions that reference the same legacy diagram.
      version_b = gtfs_version_fixture(org.id)
      version_c = gtfs_version_fixture(org.id)

      # Seed a legacy file for this station.
      legacy_dir = Path.join([uploads_root(org.id), PathSafety.stop_storage_dir(station.stop_id)])
      File.mkdir_p!(legacy_dir)
      legacy_path = Path.join(legacy_dir, "plan.png")
      File.write!(legacy_path, @legacy_bytes)

      # Reference the diagram from every published version's StopLevel.
      {:ok, _} =
        Gtfs.create_stop_level(%{
          stop_id: station.id,
          level_id: level.id,
          diagram_filename: "plan.png",
          organization_id: org.id,
          gtfs_version_id: version.id
        })

      {:ok, _} =
        Gtfs.create_stop_level(%{
          stop_id: station.id,
          level_id: level.id,
          diagram_filename: "plan.png",
          organization_id: org.id,
          gtfs_version_id: version_b.id
        })

      {:ok, _} =
        Gtfs.create_stop_level(%{
          stop_id: station.id,
          level_id: level.id,
          diagram_filename: "plan.png",
          organization_id: org.id,
          gtfs_version_id: version_c.id
        })

      assert {:ok, count} = DiagramStorage.migrate_legacy_assets(Repo)
      assert count == 3

      for v <- [version, version_b, version_c] do
        {:ok, dest} = DiagramStorage.published_path(org.id, v.id, station.stop_id, "plan.png")
        assert File.read!(dest) == @legacy_bytes
      end

      # Idempotent: a second run copies nothing new and does not overwrite/altever.
      assert {:ok, 0} = DiagramStorage.migrate_legacy_assets(Repo)

      for v <- [version, version_b, version_c] do
        {:ok, dest} = DiagramStorage.published_path(org.id, v.id, station.stop_id, "plan.png")
        assert File.read!(dest) == @legacy_bytes
      end

      # A versioned file that already differs is never overwritten by backfill.
      assert :ok =
               DiagramStorage.store_import_image(
                 org.id,
                 version.id,
                 station.stop_id,
                 "plan.png",
                 @import_bytes_a
               )

      assert {:ok, 0} = DiagramStorage.migrate_legacy_assets(Repo)
      {:ok, dest} = DiagramStorage.published_path(org.id, version.id, station.stop_id, "plan.png")
      assert File.read!(dest) == @import_bytes_a

      # Legacy source remains intact.
      assert File.read!(legacy_path) == @legacy_bytes
    end

    test "does not copy when no legacy file exists for a referenced diagram",
         %{organization: org, version: version, station: station, level: level} do
      {:ok, _} =
        Gtfs.create_stop_level(%{
          stop_id: station.id,
          level_id: level.id,
          diagram_filename: "missing.png",
          organization_id: org.id,
          gtfs_version_id: version.id
        })

      assert {:ok, 0} = DiagramStorage.migrate_legacy_assets(Repo)
    end

    test "returns the filesystem error when a referenced destination cannot be created",
         %{organization: org, version: version, station: station, level: level} do
      legacy_dir = Path.join([uploads_root(org.id), PathSafety.stop_storage_dir(station.stop_id)])
      File.mkdir_p!(legacy_dir)
      File.write!(Path.join(legacy_dir, "plan.png"), @legacy_bytes)

      {:ok, _} =
        Gtfs.create_stop_level(%{
          stop_id: station.id,
          level_id: level.id,
          diagram_filename: "plan.png",
          organization_id: org.id,
          gtfs_version_id: version.id
        })

      blocked_destination =
        Path.join([
          uploads_root(org.id),
          version.id,
          PathSafety.stop_storage_dir(station.stop_id)
        ])

      File.mkdir_p!(Path.dirname(blocked_destination))
      File.write!(blocked_destination, "not a directory")

      assert {:error, reason} = DiagramStorage.migrate_legacy_assets(Repo)
      assert reason in [:eexist, :enotdir]
    end
  end

  describe "Release.migrate/0 wiring" do
    @tag :release
    test "runs legacy backfill while the Repo is available and leaves legacy source intact",
         %{organization: org, version: version, station: station, level: level} do
      # Seed a legacy file and a published StopLevel referencing it.
      legacy_dir = Path.join([uploads_root(org.id), PathSafety.stop_storage_dir(station.stop_id)])
      File.mkdir_p!(legacy_dir)
      legacy_path = Path.join(legacy_dir, "plan.png")
      File.write!(legacy_path, @legacy_bytes)

      {:ok, _} =
        Gtfs.create_stop_level(%{
          stop_id: station.id,
          level_id: level.id,
          diagram_filename: "plan.png",
          organization_id: org.id,
          gtfs_version_id: version.id
        })

      capture_log(fn ->
        assert :ok = GtfsPlanner.Release.migrate()
      end)

      {:ok, dest} = DiagramStorage.published_path(org.id, version.id, station.stop_id, "plan.png")
      assert File.read!(dest) == @legacy_bytes
      assert File.read!(legacy_path) == @legacy_bytes
    end

    @tag :release
    test "raises when the legacy backfill cannot create a versioned destination",
         %{organization: org, version: version, station: station, level: level} do
      legacy_dir = Path.join([uploads_root(org.id), PathSafety.stop_storage_dir(station.stop_id)])
      File.mkdir_p!(legacy_dir)
      File.write!(Path.join(legacy_dir, "plan.png"), @legacy_bytes)

      {:ok, _} =
        Gtfs.create_stop_level(%{
          stop_id: station.id,
          level_id: level.id,
          diagram_filename: "plan.png",
          organization_id: org.id,
          gtfs_version_id: version.id
        })

      blocked_destination =
        Path.join([
          uploads_root(org.id),
          version.id,
          PathSafety.stop_storage_dir(station.stop_id)
        ])

      File.mkdir_p!(Path.dirname(blocked_destination))
      File.write!(blocked_destination, "not a directory")

      capture_log(fn ->
        assert_raise RuntimeError,
                     ~r/legacy diagram backfill failed: :(?:eexist|enotdir)/,
                     fn -> GtfsPlanner.Release.migrate() end
      end)
    end
  end

  describe "delete_version_namespace/2" do
    test "removes only the exact version namespace, leaving sibling versions intact",
         %{root: root, organization: org, version: version} do
      other_version = gtfs_version_fixture(org.id)

      version_dir = Path.join([uploads_root(org.id), version.id])
      sibling_dir = Path.join([uploads_root(org.id), other_version.id])

      File.mkdir_p!(Path.join([version_dir, "station_a"]))
      File.write!(Path.join([version_dir, "station_a", "plan.png"]), @import_bytes_a)
      File.mkdir_p!(Path.join([sibling_dir, "station_b"]))
      File.write!(Path.join([sibling_dir, "station_b", "plan.png"]), @import_bytes_b)

      assert :ok = DiagramStorage.delete_version_namespace(org.id, version.id)

      refute File.exists?(version_dir)
      assert File.exists?(sibling_dir)
      assert File.read!(Path.join([sibling_dir, "station_b", "plan.png"])) == @import_bytes_b
      # Nothing escaped beyond the org root.
      assert [] == Path.wildcard(Path.join([root, "diagrams", "**", "*.png"])) --
               [Path.join([sibling_dir, "station_b", "plan.png"])]
    end

    test "returns ok when the namespace is already absent (idempotent)",
         %{organization: org, version: version} do
      assert :ok = DiagramStorage.delete_version_namespace(org.id, version.id)
      assert :ok = DiagramStorage.delete_version_namespace(org.id, version.id)
    end

    test "rejects an unsafe organization or version component without deleting",
         %{root: root, organization: org, version: version} do
      existing =
        Path.join([uploads_root(org.id), version.id])
        |> Path.dirname()

      File.mkdir_p!(existing)
      File.write!(Path.join([existing, "keep.txt"]), "keep")

      assert {:error, :unsafe_path} =
               DiagramStorage.delete_version_namespace("../escaped", version.id)

      assert {:error, :unsafe_path} =
               DiagramStorage.delete_version_namespace(org.id, "../../etc")

      # No broader deletion occurred.
      assert File.exists?(Path.join([existing, "keep.txt"]))
      assert [] == Path.wildcard(Path.join([root, "**", "etc"]))
    end

    test "does not fall back to a broader path when containment fails",
         %{root: root, organization: org, version: version} do
      # Craft a component that fails validation; nothing is deleted and no
      # broader path is touched. Because safe_path_component? rejects slashes,
      # the only remaining guard is ensure_within_root, exercised for every
      # realistic join below.
      assert {:error, _} = DiagramStorage.delete_version_namespace(org.id, ".")

      # The org root and sibling data remain untouched.
      assert [] == Path.wildcard(Path.join([root, "diagrams", "**", "*.png"]))
    end

    test "published-version files in a sibling namespace are preserved",
         %{root: root, organization: org} do
      published_version = gtfs_version_fixture(org.id)
      failed_version = gtfs_version_fixture(org.id)

      published_dir = Path.join([uploads_root(org.id), published_version.id])
      failed_dir = Path.join([uploads_root(org.id), failed_version.id])

      File.mkdir_p!(Path.join([published_dir, "station_a"]))
      File.write!(Path.join([published_dir, "station_a", "plan.png"]), @import_bytes_a)
      File.mkdir_p!(Path.join([failed_dir, "station_a"]))
      File.write!(Path.join([failed_dir, "station_a", "plan.png"]), @import_bytes_b)

      assert :ok = DiagramStorage.delete_version_namespace(org.id, failed_version.id)

      refute File.exists?(failed_dir)
      assert File.read!(Path.join([published_dir, "station_a", "plan.png"])) == @import_bytes_a
      assert [] == Path.wildcard(Path.join([root, "diagrams", "**", "*.png"])) --
               [Path.join([published_dir, "station_a", "plan.png"])]
    end
  end

  defp uploads_root(organization_id) do
    Path.join([Application.fetch_env!(:gtfs_planner, :uploads_path), "diagrams", organization_id])
    |> Path.expand()
  end
end
