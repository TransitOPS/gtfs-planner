defmodule GtfsPlanner.Gtfs.ValidatorArtifactLifecycleTest do
  use GtfsPlanner.DataCase

  alias GtfsPlanner.Gtfs.Validator
  alias GtfsPlanner.Otp
  alias GtfsPlanner.Otp.ArtifactPath
  alias GtfsPlanner.Validations

  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  describe "validate/3 artifact lifecycle" do
    setup do
      organization = organization_fixture()
      gtfs_version = gtfs_version_fixture(organization.id)

      on_exit(fn ->
        File.rm_rf(ArtifactPath.artifact_dir(organization.id, gtfs_version.id))
      end)

      %{organization: organization, gtfs_version: gtfs_version}
    end

    test "preserves existing OTP artifact when validation fails", %{
      organization: organization,
      gtfs_version: gtfs_version
    } do
      agency_fixture(organization.id, gtfs_version.id)

      zip_path = ArtifactPath.artifact_zip_path(organization.id, gtfs_version.id)
      zip_binary = "existing-otp-artifact"
      File.mkdir_p!(Path.dirname(zip_path))
      File.write!(zip_path, zip_binary)

      assert {:ok, _artifact} =
               Otp.upsert_artifact(%{
                 organization_id: organization.id,
                 gtfs_version_id: gtfs_version.id,
                 zip_path: zip_path,
                 content_hash: "existinghash",
                 file_size_bytes: byte_size(zip_binary),
                 manifest_json: %{"files" => ["agency.txt"]}
               })

      {:ok, run} = Validations.create_validation_run(organization.id, gtfs_version.id, "mobility_data")

      original_validator_path = Application.get_env(:gtfs_planner, :gtfs_validator_path)
      Application.put_env(:gtfs_planner, :gtfs_validator_path, nil)

      on_exit(fn ->
        Application.put_env(:gtfs_planner, :gtfs_validator_path, original_validator_path)
      end)

      assert {:error, :validator_path_not_configured} =
               Validator.validate(organization.id, gtfs_version.id, validation_run_id: run.id)

      assert File.regular?(zip_path)
      assert {:ok, _artifact} = Otp.fetch_artifact(organization.id, gtfs_version.id)
    end
  end
end
