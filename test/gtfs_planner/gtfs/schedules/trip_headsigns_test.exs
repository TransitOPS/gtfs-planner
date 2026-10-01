defmodule GtfsPlanner.Gtfs.Schedules.TripHeadsignsTest do
  @moduledoc """
  Focused coverage for the audited trip headsign writer (EV-6): fenced changes
  write exactly their trips under one shared operation id, a no-op writes
  nothing, a stale reviewed value writes nothing, and an out-of-scope id is
  rejected. Every helper call holds current editor membership and the
  published route and pattern locks, as the production callers do.

  The focused gate command is deferred to branch review:
  `MIX_ENV=test MIX_TEST_PARTITION=_hs20 mix test
  test/gtfs_planner/gtfs/schedules/trip_headsigns_test.exs`.
  """

  use GtfsPlanner.DataCase

  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Authorization
  alias GtfsPlanner.Gtfs.AuditContext
  alias GtfsPlanner.Gtfs.ChangeLog
  alias GtfsPlanner.Gtfs.RoutePatterns
  alias GtfsPlanner.Gtfs.Schedules
  alias GtfsPlanner.Gtfs.Trip
  alias GtfsPlanner.Repo

  @default "Lincoln City"

  setup do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    actor = editor_fixture(organization)

    route = route_fixture(organization.id, version.id, %{route_id: "HS20"})

    bundle =
      schedule_pattern_fixture(organization.id, version.id, %{
        route_id: "HS20",
        route_pattern_id: "HS20-0",
        headsign: @default,
        timing_name: "Weekday",
        stops: [{"A", 0, 0, 1}, {"B", 300, 330, 1}]
      })

    trips =
      Enum.map(1..3, fn index ->
        schedule_trip_fixture(organization.id, version.id, "HS20", bundle, %{
          service_id: "WK",
          trip_id: "hs20-#{index}",
          trip_headsign: @default
        })
        |> Map.fetch!(:trip)
      end)

    %{
      organization: organization,
      version: version,
      route: route,
      bundle: bundle,
      trips: trips,
      audit: %AuditContext{
        organization_id: organization.id,
        gtfs_version_id: version.id,
        station_stop_id: nil,
        actor_id: actor.id,
        actor_email: actor.email
      }
    }
  end

  test "three changes write three headsigns and three audited rows under one operation id",
       context do
    [trip_a, trip_b, trip_c] = context.trips

    changes = [
      %{id: trip_a.id, trip_id: trip_a.trip_id, from: @default, to: "Roads End"},
      %{id: trip_b.id, trip_id: trip_b.trip_id, from: @default, to: "Boston"},
      %{id: trip_c.id, trip_id: trip_c.trip_id, from: @default, to: nil}
    ]

    operation_id = Ecto.UUID.generate()

    assert {:ok, ^changes} =
             authorized_transaction(context, fn ->
               Schedules.write_trip_headsigns!(changes, operation_id, context.audit)
             end)

    assert %{
             trip_a.id => "Roads End",
             trip_b.id => "Boston",
             trip_c.id => nil
           } == reloaded_headsigns(context.trips)

    logs = trip_logs(context)

    assert length(logs) == 3
    assert Enum.all?(logs, &(&1.action == "updated" and &1.entity_type == "trip"))

    assert Enum.sort(Enum.map(logs, & &1.entity_id)) ==
             Enum.sort([trip_a.id, trip_b.id, trip_c.id])

    # One shared operation id, and every row names all three written trips.
    assert Enum.uniq(Enum.map(logs, & &1.changed_fields["operation_id"])) == [operation_id]

    for log <- logs do
      assert Enum.sort(log.changed_fields["affected_trip_ids"]) ==
               Enum.sort([trip_a.id, trip_b.id, trip_c.id])
    end
  end

  test "the before and after snapshots carry the old and new trip_headsign and differ in nothing else",
       context do
    [trip_a, trip_b | _rest] = context.trips

    changes = [
      %{id: trip_a.id, trip_id: trip_a.trip_id, from: @default, to: "Roads End"},
      %{id: trip_b.id, trip_id: trip_b.trip_id, from: @default, to: "Boston"}
    ]

    assert {:ok, _written} =
             authorized_transaction(context, fn ->
               Schedules.write_trip_headsigns!(changes, Ecto.UUID.generate(), context.audit)
             end)

    logs = Map.new(trip_logs(context), &{&1.entity_id, &1.changed_fields})

    assert logs[trip_a.id]["before"]["trip_headsign"] == @default
    assert logs[trip_a.id]["after"]["trip_headsign"] == "Roads End"
    assert logs[trip_b.id]["before"]["trip_headsign"] == @default
    assert logs[trip_b.id]["after"]["trip_headsign"] == "Boston"

    # A headsign write moves no other trip fact: the snapshots agree once the
    # headsign is removed from both.
    assert Map.delete(logs[trip_a.id]["before"], "trip_headsign") ==
             Map.delete(logs[trip_a.id]["after"], "trip_headsign")
  end

  test "a change whose from equals to writes nothing and adds no audit row", context do
    [trip_a | _rest] = context.trips
    original = Repo.get!(Trip, trip_a.id)

    changes = [%{id: trip_a.id, trip_id: trip_a.trip_id, from: @default, to: @default}]

    assert {:ok, []} =
             authorized_transaction(context, fn ->
               Schedules.write_trip_headsigns!(changes, Ecto.UUID.generate(), context.audit)
             end)

    after_write = Repo.get!(Trip, trip_a.id)
    assert after_write.trip_headsign == @default
    assert DateTime.compare(after_write.updated_at, original.updated_at) == :eq
    assert trip_logs(context) == []
  end

  test "a no-op among writes is skipped while the real change writes", context do
    [trip_a, trip_b | _rest] = context.trips
    untouched = Repo.get!(Trip, trip_b.id)

    changes = [
      %{id: trip_a.id, trip_id: trip_a.trip_id, from: @default, to: "Roads End"},
      %{id: trip_b.id, trip_id: trip_b.trip_id, from: @default, to: @default}
    ]

    operation_id = Ecto.UUID.generate()

    assert {:ok, [written]} =
             authorized_transaction(context, fn ->
               Schedules.write_trip_headsigns!(changes, operation_id, context.audit)
             end)

    assert written.id == trip_a.id

    # The untouched trip keeps its row untouched even though it was selected.
    reloaded = Repo.get!(Trip, trip_b.id)
    assert reloaded.trip_headsign == @default
    assert DateTime.compare(reloaded.updated_at, untouched.updated_at) == :eq

    assert [log] = trip_logs(context)
    assert log.entity_id == trip_a.id
    assert log.changed_fields["affected_trip_ids"] == [trip_a.id]
  end

  test "a change whose from differs from the current normalized value rolls back stale and writes nothing",
       context do
    [trip_a, trip_b | _rest] = context.trips

    changes = [
      %{id: trip_a.id, trip_id: trip_a.trip_id, from: @default, to: "Roads End"},
      %{id: trip_b.id, trip_id: trip_b.trip_id, from: "Boston", to: "Salem"}
    ]

    assert {:error, {:stale, [stale]}} =
             authorized_transaction(context, fn ->
               Schedules.write_trip_headsigns!(changes, Ecto.UUID.generate(), context.audit)
             end)

    assert %{id: id, trip_id: trip_id, reviewed: "Boston", current: @default} = stale
    assert id == trip_b.id
    assert trip_id == trip_b.trip_id

    assert %{trip_a.id => @default, trip_b.id => @default} ==
             reloaded_headsigns([trip_a, trip_b])

    assert trip_logs(context) == []
  end

  test "a padded stored value still matches the trimmed reviewed from", context do
    [trip_a, trip_b | _rest] = context.trips

    # Import stores headsigns untrimmed, so the padded value bypasses the Trip
    # changeset trimming exactly like a real import.
    imported =
      imported_trip(context, trip_b.timed_pattern_id, " #{@default}")

    changes = [
      %{id: trip_a.id, trip_id: trip_a.trip_id, from: @default, to: "Roads End"},
      %{id: imported.id, trip_id: imported.trip_id, from: @default, to: "Boston"}
    ]

    assert {:ok, _written} =
             authorized_transaction(context, fn ->
               Schedules.write_trip_headsigns!(changes, Ecto.UUID.generate(), context.audit)
             end)

    assert reloaded_headsigns([trip_a, imported]) ==
             %{trip_a.id => "Roads End", imported.id => "Boston"}

    logs = Map.new(trip_logs(context), &{&1.entity_id, &1.changed_fields})

    # Each before snapshot carries the raw stored value, padded or not.
    assert logs[trip_a.id]["before"]["trip_headsign"] == @default
    assert logs[imported.id]["before"]["trip_headsign"] == " #{@default}"
    assert logs[trip_a.id]["after"]["trip_headsign"] == "Roads End"
    assert logs[imported.id]["after"]["trip_headsign"] == "Boston"
  end

  test "an id from another organization rolls back :invalid_selection and writes nothing",
       context do
    foreign_organization =
      organization_fixture(%{
        alias: "trip-headsigns-foreign-#{System.unique_integer([:positive])}"
      })

    foreign_version = gtfs_version_fixture(foreign_organization.id)
    route_fixture(foreign_organization.id, foreign_version.id, %{route_id: "HS20"})

    foreign_trip =
      trip_fixture(foreign_organization.id, foreign_version.id, "HS20", trip_headsign: @default)

    changes = [
      %{id: foreign_trip.id, trip_id: foreign_trip.trip_id, from: @default, to: "Boston"}
    ]

    assert {:error, :invalid_selection} =
             authorized_transaction(context, fn ->
               Schedules.write_trip_headsigns!(changes, Ecto.UUID.generate(), context.audit)
             end)

    # Neither the selected foreign trip nor the local trips moved, and neither
    # organization recorded an audit row.
    assert Repo.get!(Trip, foreign_trip.id).trip_headsign == @default

    assert reloaded_headsigns(context.trips)
           |> Map.values()
           |> Enum.all?(&(&1 == @default))

    assert trip_logs(context) == []

    foreign_logs =
      Repo.all(from(l in ChangeLog, where: l.organization_id == ^foreign_organization.id))

    assert foreign_logs == []

    # A missing id is the same invalid selection.
    ghost = [%{id: Ecto.UUID.generate(), trip_id: "ghost", from: @default, to: "Boston"}]

    assert {:error, :invalid_selection} =
             authorized_transaction(context, fn ->
               Schedules.write_trip_headsigns!(ghost, Ecto.UUID.generate(), context.audit)
             end)

    assert trip_logs(context) == []
  end

  test "the helper rejects out-of-transaction invocation before reading or writing", context do
    [trip | _] = context.trips
    before_trip = Repo.reload!(trip)
    before_logs = trip_logs(context)

    assert_raise ArgumentError, ~r/authorized transaction/, fn ->
      Schedules.write_trip_headsigns!(
        [%{id: trip.id, trip_id: trip.trip_id, from: @default, to: "Roads End"}],
        Ecto.UUID.generate(),
        context.audit
      )
    end

    assert Repo.reload!(trip) == before_trip
    assert trip_logs(context) == before_logs
  end

  defp authorized_transaction(context, fun) do
    Repo.transaction(fn ->
      Authorization.lock_editor!(context.audit)
      route = RoutePatterns.lock_published_route!(context.audit, context.route.route_id)
      RoutePatterns.lock_pattern!(route, context.bundle.pattern.id)
      fun.()
    end)
  end

  defp reloaded_headsigns(trips) do
    Map.new(trips, fn trip -> {trip.id, Repo.get!(Trip, trip.id).trip_headsign} end)
  end

  defp trip_logs(context) do
    Repo.all(
      from(l in ChangeLog,
        where: l.organization_id == ^context.organization.id and l.entity_type == "trip",
        order_by: [asc: l.entity_external_id, asc: l.inserted_at]
      )
    )
  end

  defp imported_trip(context, timed_pattern_id, headsign) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    row = %{
      id: Ecto.UUID.generate(),
      trip_id: "trip_import_#{System.unique_integer([:positive])}",
      route_id: "HS20",
      service_id: "WK",
      direction_id: 0,
      trip_headsign: headsign,
      route_pattern_id: "HS20-0",
      timed_pattern_id: timed_pattern_id,
      pattern_derivation_state: "linked",
      organization_id: context.organization.id,
      gtfs_version_id: context.version.id,
      inserted_at: now,
      updated_at: now
    }

    {1, _} = Repo.insert_all(Trip, [row])

    Repo.get!(Trip, row.id)
  end
end
