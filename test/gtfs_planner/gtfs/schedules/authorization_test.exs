defmodule GtfsPlanner.Gtfs.Schedules.AuthorizationTest do
  use GtfsPlanner.DataCase

  import Ecto.Query
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.ScheduleEditingFixtures

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Accounts.UserOrgMembership
  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.{ChangeLog, Frequency, StopTime, Transfer, Trip}
  alias GtfsPlanner.Repo

  setup do
    scope = editing_scope!("12")
    trip = linked_trip!(scope, "07:00:00")
    membership = Accounts.get_user_org_membership(scope.actor.id, scope.organization.id)
    %{scope: scope, trip: trip, membership: membership}
  end

  test "revoked editor cannot enter any schedule write transaction", %{
    scope: scope,
    trip: trip,
    membership: membership
  } do
    command = {:shift, [trip.id], 300, nil}
    assert {:ok, review} = Gtfs.review_trip_change("12", command, scope.audit)
    before = snapshot(scope)
    deactivate_membership_fixture(membership)

    assert {:error, :forbidden} = Gtfs.create_trips("12", create_attrs(scope), scope.audit)

    assert {:error, :forbidden} =
             Gtfs.update_trip(
               "12",
               trip.id,
               %{trip_short_name: "42"},
               trip.updated_at,
               scope.audit
             )

    assert {:error, :forbidden} =
             Gtfs.duplicate_trip(
               "12",
               trip.id,
               %{start_time: "08:00:00", timed_pattern_id: scope.bundle.timing.id},
               scope.audit
             )

    assert {:error, :forbidden} = Gtfs.delete_trips("12", scope.service, [trip.id], scope.audit)

    assert {:error, :forbidden} =
             Gtfs.apply_trip_change("12", command, {:reviewed, review.fingerprint}, scope.audit)

    assert {:error, :forbidden} =
             Gtfs.apply_timetable_paste("12", %{}, %{}, "reviewed", scope.audit)

    assert {:ok, _read} = Gtfs.review_trip_change("12", command, scope.audit)
    assert snapshot(scope) == before
  end

  test "removed editor role refuses a captured restore and leaves every row and log intact", %{
    scope: scope,
    trip: trip,
    membership: membership
  } do
    command = {:shift, [trip.id], 300, nil}
    assert {:ok, review} = Gtfs.review_trip_change("12", command, scope.audit)

    assert {:ok, applied} =
             Gtfs.apply_trip_change("12", command, {:reviewed, review.fingerprint}, scope.audit)

    before = snapshot(scope)

    membership
    |> UserOrgMembership.changeset(%{roles: ["pathways_studio_admin"]})
    |> Repo.update!()

    assert {:error, :forbidden} = Gtfs.restore_trips("12", applied.restore, scope.audit)
    assert snapshot(scope) == before
  end

  defp create_attrs(scope) do
    %{
      pattern_id: scope.bundle.pattern.id,
      timed_pattern_id: scope.bundle.timing.id,
      service_id: scope.service,
      start_time: "08:00:00",
      repeat: nil
    }
  end

  defp snapshot(scope) do
    for schema <- [Trip, StopTime, Frequency, Transfer, ChangeLog], into: %{} do
      {schema,
       Repo.all(
         from(row in schema,
           where:
             row.organization_id == ^scope.organization.id and
               row.gtfs_version_id == ^scope.version.id,
           order_by: [asc: row.id]
         )
       )}
    end
  end
end
