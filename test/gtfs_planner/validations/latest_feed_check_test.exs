defmodule GtfsPlanner.Validations.LatestFeedCheckTest do
  use GtfsPlanner.DataCase, async: true

  alias GtfsPlanner.Validations
  alias GtfsPlanner.Validations.ValidationRun

  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  setup do
    organization = organization_fixture()
    gtfs_version = gtfs_version_fixture(organization.id)
    %{organization: organization, gtfs_version: gtfs_version}
  end

  test "ignores a newer station_reachability run", %{
    organization: organization,
    gtfs_version: gtfs_version
  } do
    check =
      insert_run(organization, gtfs_version, %{
        run_type: "mobility_data",
        status: "completed",
        started_at: ~U[2026-09-01 09:00:00Z]
      })

    insert_run(organization, gtfs_version, %{
      run_type: "station_reachability",
      status: "completed",
      started_at: ~U[2026-09-02 09:00:00Z]
    })

    assert %ValidationRun{id: id} =
             Validations.latest_feed_check(organization.id, gtfs_version.id)

    assert id == check.id
  end

  test "ignores a newer running run and returns the newest finished run", %{
    organization: organization,
    gtfs_version: gtfs_version
  } do
    insert_run(organization, gtfs_version, %{
      run_type: "mobility_data",
      status: "completed",
      started_at: ~U[2026-09-01 09:00:00Z]
    })

    failed =
      insert_run(organization, gtfs_version, %{
        run_type: "mobility_data",
        status: "failed",
        started_at: ~U[2026-09-02 09:00:00Z]
      })

    insert_run(organization, gtfs_version, %{
      run_type: "mobility_data",
      status: "running",
      started_at: ~U[2026-09-03 09:00:00Z]
    })

    assert %ValidationRun{id: id, status: "failed"} =
             Validations.latest_feed_check(organization.id, gtfs_version.id)

    assert id == failed.id
  end

  test "ignores a newer run from another version", %{
    organization: organization,
    gtfs_version: gtfs_version
  } do
    check =
      insert_run(organization, gtfs_version, %{
        run_type: "mobility_data",
        status: "completed",
        started_at: ~U[2026-09-01 09:00:00Z]
      })

    other_version = gtfs_version_fixture(organization.id)

    insert_run(organization, other_version, %{
      run_type: "mobility_data",
      status: "completed",
      started_at: ~U[2026-09-02 09:00:00Z]
    })

    assert %ValidationRun{id: id} =
             Validations.latest_feed_check(organization.id, gtfs_version.id)

    assert id == check.id
  end

  test "ignores a newer run from another organization", %{
    organization: organization,
    gtfs_version: gtfs_version
  } do
    check =
      insert_run(organization, gtfs_version, %{
        run_type: "mobility_data",
        status: "completed",
        started_at: ~U[2026-09-01 09:00:00Z]
      })

    other_organization = organization_fixture()
    other_version = gtfs_version_fixture(other_organization.id)

    insert_run(other_organization, other_version, %{
      run_type: "mobility_data",
      status: "completed",
      started_at: ~U[2026-09-02 09:00:00Z]
    })

    assert %ValidationRun{id: id} =
             Validations.latest_feed_check(organization.id, gtfs_version.id)

    assert id == check.id
  end

  test "returns nil when there are no runs", %{
    organization: organization,
    gtfs_version: gtfs_version
  } do
    assert Validations.latest_feed_check(organization.id, gtfs_version.id) == nil
  end

  test "returns the lower id when started_at values tie", %{
    organization: organization,
    gtfs_version: gtfs_version
  } do
    lower_id = "00000000-0000-0000-0000-000000000001"

    insert_run(organization, gtfs_version, %{
      id: lower_id,
      run_type: "mobility_data",
      status: "completed",
      started_at: ~U[2026-09-01 09:00:00Z]
    })

    insert_run(organization, gtfs_version, %{
      id: "00000000-0000-0000-0000-000000000002",
      run_type: "mobility_data",
      status: "completed",
      started_at: ~U[2026-09-01 09:00:00Z]
    })

    assert %ValidationRun{id: ^lower_id} =
             Validations.latest_feed_check(organization.id, gtfs_version.id)
  end

  defp insert_run(organization, gtfs_version, attrs) do
    {id, attrs} = Map.pop(attrs, :id, Ecto.UUID.generate())

    %ValidationRun{id: id, organization_id: organization.id, gtfs_version_id: gtfs_version.id}
    |> ValidationRun.changeset(attrs)
    |> Repo.insert!()
  end
end
