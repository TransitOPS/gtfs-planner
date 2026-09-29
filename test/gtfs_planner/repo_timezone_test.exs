defmodule GtfsPlanner.RepoTimezoneTest do
  use GtfsPlanner.DataCase, async: false

  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Gtfs.ExportRuns

  @actor %{id: Ecto.UUID.generate(), email: "exporter@example.com"}
  @tolerance_seconds 5

  test "runs every database session in UTC" do
    %Postgrex.Result{rows: [[time_zone]]} = Repo.query!("SHOW TIME ZONE")

    assert time_zone in ["UTC", "Etc/UTC"]
  end

  test "stores database-clock timestamps as UTC wall-clock time" do
    %Postgrex.Result{rows: [[stored]]} = Repo.query!("SELECT CURRENT_TIMESTAMP::timestamp")

    stored_utc = DateTime.from_naive!(stored, "Etc/UTC")

    assert abs(DateTime.diff(stored_utc, DateTime.utc_now())) <= @tolerance_seconds
  end

  test "stamps a claimed export run's started_at in the same clock as its inserted_at" do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    {:ok, run} = ExportRuns.create_pending(organization.id, version.id, @actor, :full)

    {:ok, claimed, _generation, _token} = ExportRuns.claim(organization.id, run.id, :build)

    assert abs(DateTime.diff(claimed.started_at, claimed.inserted_at)) <= @tolerance_seconds
  end
end
