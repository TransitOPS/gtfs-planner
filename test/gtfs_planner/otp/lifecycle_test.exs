defmodule GtfsPlanner.Otp.LifecycleTest do
  use GtfsPlanner.DataCase

  alias GtfsPlanner.Otp
  alias GtfsPlanner.Otp.ArtifactPath
  alias GtfsPlanner.Otp.Lifecycle

  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  describe "purge_artifact_on_success/2" do
    setup do
      organization = organization_fixture()
      gtfs_version = gtfs_version_fixture(organization.id)

      on_exit(fn ->
        File.rm_rf(ArtifactPath.artifact_dir(organization.id, gtfs_version.id))
      end)

      %{organization: organization, gtfs_version: gtfs_version}
    end

    test "deletes zip file and artifact record", %{organization: organization, gtfs_version: gtfs_version} do
      zip_path = ArtifactPath.artifact_zip_path(organization.id, gtfs_version.id)
      zip_binary = "otp-zip-binary"

      File.mkdir_p!(Path.dirname(zip_path))
      File.write!(zip_path, zip_binary)

      assert {:ok, _artifact} =
               Otp.upsert_artifact(%{
                 organization_id: organization.id,
                 gtfs_version_id: gtfs_version.id,
                 zip_path: zip_path,
                 content_hash: "abc123",
                 file_size_bytes: byte_size(zip_binary),
                 manifest_json: %{"files" => ["agency.txt"]}
               })

      assert {:ok, :purged} = Lifecycle.purge_artifact_on_success(organization.id, gtfs_version.id)
      refute File.exists?(zip_path)
      assert {:error, :not_found} = Otp.fetch_artifact(organization.id, gtfs_version.id)
    end

    test "returns not_found when artifact does not exist", %{
      organization: organization,
      gtfs_version: gtfs_version
    } do
      assert {:ok, :not_found} = Lifecycle.purge_artifact_on_success(organization.id, gtfs_version.id)
    end
  end
end
