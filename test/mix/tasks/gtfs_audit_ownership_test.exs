defmodule Mix.Tasks.Gtfs.AuditOwnershipTest do
  use GtfsPlanner.DataCase, async: false

  import ExUnit.CaptureIO
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.OperationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Gtfs.Route
  alias GtfsPlanner.Release

  test "Mix and release entry points report a clean database" do
    mix_output = capture_io(fn -> assert :ok = Mix.Task.rerun("gtfs.audit_ownership", []) end)
    assert mix_output =~ "routes→gtfs_versions\t0\t"
    assert mix_output =~ "vehicles.garage_id→garages\t0\t"

    release_output = capture_io(fn -> assert :ok = Release.audit_ownership() end)
    assert release_output =~ "routes→gtfs_versions\t0\t"
    assert release_output =~ "relief_points→gtfs_versions\t0\t"
  end

  test "an asset-parent mismatch makes the Mix command exit and the release API return its count" do
    org = organization_fixture()
    foreign_org = organization_fixture()
    garage = garage_fixture(foreign_org.id)
    id = Ecto.UUID.generate()

    Repo.query!("ALTER TABLE vehicles DROP CONSTRAINT vehicles_garage_id_owner_fkey")

    Repo.query!(
      """
      INSERT INTO vehicles (id, organization_id, vehicle_id, garage_id, inserted_at, updated_at)
      VALUES ($1, $2, 'foreign-garage', $3, now(), now())
      """,
      Enum.map([id, org.id, garage.id], &Ecto.UUID.dump!/1)
    )

    mix_output =
      capture_io(fn ->
        assert catch_exit(Mix.Task.rerun("gtfs.audit_ownership", [])) == {:shutdown, 1}
      end)

    assert mix_output =~ "vehicles.garage_id→garages\t1\t#{id}"

    assert capture_io(fn -> assert {:error, 1} = Release.audit_ownership() end) =~
             "vehicles.garage_id→garages\t1\t#{id}"
  end

  test "Mix exits nonzero and release returns the anomaly count" do
    org = organization_fixture()
    foreign_org = organization_fixture()
    foreign_version = gtfs_version_fixture(foreign_org.id)
    id = Ecto.UUID.generate()

    Repo.query!("ALTER TABLE routes DROP CONSTRAINT IF EXISTS routes_version_owner_fkey")

    now = DateTime.utc_now()

    {1, _} =
      Repo.insert_all(Route, [
        %{
          id: id,
          route_id: "audit_task_#{System.unique_integer([:positive])}",
          route_type: 3,
          organization_id: org.id,
          gtfs_version_id: foreign_version.id,
          inserted_at: now,
          updated_at: now
        }
      ])

    mix_output =
      capture_io(fn ->
        assert catch_exit(Mix.Task.rerun("gtfs.audit_ownership", [])) == {:shutdown, 1}
      end)

    assert mix_output =~ "routes→gtfs_versions\t1\t#{id}"

    release_output = capture_io(fn -> assert {:error, 1} = Release.audit_ownership() end)
    assert release_output =~ "routes→gtfs_versions\t1\t#{id}"
  end
end
