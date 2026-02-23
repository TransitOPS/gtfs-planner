defmodule GtfsPlanner.Otp.GraphPreflightTest do
  use GtfsPlanner.DataCase

  alias GtfsPlanner.Otp
  alias GtfsPlanner.Otp.GraphPath
  alias GtfsPlanner.Otp.GraphPreflight

  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  setup do
    organization = organization_fixture()
    gtfs_version = gtfs_version_fixture(organization.id)

    previous_env = %{
      java_path: Application.get_env(:gtfs_planner, :java_path),
      otp_jar_path: Application.get_env(:gtfs_planner, :otp_jar_path),
      otp_osm_path: Application.get_env(:gtfs_planner, :otp_osm_path),
      otp_runtime_path: Application.get_env(:gtfs_planner, :otp_runtime_path)
    }

    on_exit(fn ->
      restore_env(:java_path, previous_env.java_path)
      restore_env(:otp_jar_path, previous_env.otp_jar_path)
      restore_env(:otp_osm_path, previous_env.otp_osm_path)
      restore_env(:otp_runtime_path, previous_env.otp_runtime_path)

      File.rm_rf(GraphPath.workspace_dir(organization.id, gtfs_version.id))
    end)

    %{organization: organization, gtfs_version: gtfs_version}
  end

  test "run/2 returns :ok when all graph dependencies are valid", %{
    organization: organization,
    gtfs_version: gtfs_version
  } do
    tmp_dir =
      Path.join(System.tmp_dir!(), "graph-preflight-#{System.unique_integer([:positive])}")

    java_path = Path.join(tmp_dir, "java")
    otp_jar_path = Path.join(tmp_dir, "otp.jar")
    otp_osm_path = Path.join(tmp_dir, "region.osm.pbf")
    gtfs_zip_path = Path.join(tmp_dir, "gtfs.zip")
    runtime_path = Path.join(tmp_dir, "runtime")

    File.mkdir_p!(tmp_dir)
    File.write!(java_path, "java")
    File.write!(otp_jar_path, "jar")
    File.write!(otp_osm_path, "osm")
    File.write!(gtfs_zip_path, "zip")

    Application.put_env(:gtfs_planner, :java_path, java_path)
    Application.put_env(:gtfs_planner, :otp_jar_path, otp_jar_path)
    Application.put_env(:gtfs_planner, :otp_osm_path, otp_osm_path)
    Application.put_env(:gtfs_planner, :otp_runtime_path, runtime_path)

    assert {:ok, _artifact} =
             Otp.upsert_artifact(%{
               organization_id: organization.id,
               gtfs_version_id: gtfs_version.id,
               zip_path: gtfs_zip_path,
               content_hash: "hash",
               file_size_bytes: 3,
               manifest_json: %{"files" => ["agency.txt"]}
             })

    assert :ok = GraphPreflight.run(organization.id, gtfs_version.id)
    assert File.dir?(GraphPath.data_dir(organization.id, gtfs_version.id))

    File.rm_rf(tmp_dir)
  end

  test "run/2 returns structured issues when dependencies are missing", %{
    organization: organization,
    gtfs_version: gtfs_version
  } do
    Application.delete_env(:gtfs_planner, :java_path)
    Application.delete_env(:gtfs_planner, :otp_jar_path)
    Application.delete_env(:gtfs_planner, :otp_osm_path)

    assert {:error, issues} = GraphPreflight.run(organization.id, gtfs_version.id)

    issue_codes = MapSet.new(Enum.map(issues, & &1.code))

    assert MapSet.member?(issue_codes, :missing_java_path)
    assert MapSet.member?(issue_codes, :missing_otp_jar_path)
    assert MapSet.member?(issue_codes, :invalid_otp_osm_path)
    assert MapSet.member?(issue_codes, :missing_gtfs_artifact)
  end

  defp restore_env(key, nil), do: Application.delete_env(:gtfs_planner, key)
  defp restore_env(key, value), do: Application.put_env(:gtfs_planner, key, value)
end
