defmodule GtfsPlanner.Gtfs.Schedules.AuditSnapshotsTest do
  # CR-5 and INV-4: the batch snapshot `Schedules.trip_audit_snapshots/3` builds is
  # compared with the `before` an ordinary `Gtfs.update_trip/5` edit stores in
  # `change_logs`, so the shape is asserted from the recorded log rather than from
  # the helper the function shares. Fixtures are created inside the SQL Sandbox
  # transaction and rolled back.
  #
  # The focused gate command is deferred to branch review:
  # `mix test test/gtfs_planner/gtfs/schedules/audit_snapshots_test.exs`.
  use GtfsPlanner.DataCase

  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.AuditContext
  alias GtfsPlanner.Gtfs.ChangeLog
  alias GtfsPlanner.Gtfs.Schedules
  alias GtfsPlanner.Repo

  setup do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    actor = editor_fixture(organization)

    %{
      organization: organization,
      version: version,
      actor: actor,
      audit: audit_context(organization, version, actor)
    }
  end

  describe "the batch snapshot" do
    test "a linked trip's snapshot equals the before snapshot update_trip/5 records",
         context do
      scope = scope!(context.organization, context.version, "12e", timing_name: "Standard")

      trip =
        trip!(scope, %{
          trip_id: "12e-0-0600",
          start_time: "06:00:00",
          frequencies: [
            %{start_time: "09:00:00", headway_secs: 1200},
            %{start_time: "10:00:00", headway_secs: 900}
          ]
        })

      snapshots =
        Schedules.trip_audit_snapshots(context.organization.id, context.version.id, [trip])

      assert Map.keys(snapshots) == [trip.id]
      assert snapshots[trip.id]["trip_id"] == "12e-0-0600"
      assert snapshots[trip.id]["timing_name"] == "Standard"
      assert snapshots[trip.id]["pattern_derivation_state"] == "linked"
      assert snapshots[trip.id]["start_time"] == "06:00:00"
      assert snapshots[trip.id]["stop_time_count"] == 3

      # A linked trip's times are reconstructible from its timing, so its
      # snapshot carries no stop-time rows.
      refute Map.has_key?(snapshots[trip.id], "stop_times")

      assert snapshots[trip.id]["frequencies"] == [
               %{
                 "start_time" => "09:00:00",
                 "end_time" => "12:00:00",
                 "headway_secs" => 1200,
                 "exact_times" => 0
               },
               %{
                 "start_time" => "10:00:00",
                 "end_time" => "12:00:00",
                 "headway_secs" => 900,
                 "exact_times" => 0
               }
             ]

      assert {:ok, updated} =
               Gtfs.update_trip(
                 "12e",
                 trip.id,
                 %{trip_headsign: "Express"},
                 trip.updated_at,
                 context.audit
               )

      assert updated.trip_headsign == "Express"

      assert [log] = trip_logs(context)
      assert log.changed_fields["before"] == snapshots[trip.id]
      refute log.changed_fields["before"] == log.changed_fields["after"]
    end

    test "a custom trip's snapshot carries its stop times and equals the recorded before",
         context do
      scope = scope!(context.organization, context.version, "12c")

      trip =
        trip!(scope, %{
          trip_id: "12c-0-0600",
          state: "custom",
          stop_times: [
            {"A", "06:00:00", "06:00:00"},
            {"B", "06:05:00", "06:05:30"},
            {"C", "06:12:00", "06:12:00"}
          ]
        })

      assert trip.pattern_derivation_state == "custom"
      assert trip.timed_pattern_id == nil

      snapshots =
        Schedules.trip_audit_snapshots(context.organization.id, context.version.id, [trip])

      assert snapshots[trip.id]["timing_name"] == nil
      assert snapshots[trip.id]["start_time"] == "06:00:00"
      assert snapshots[trip.id]["stop_time_count"] == 3

      assert snapshots[trip.id]["stop_times"] == [
               %{"stop_id" => "A", "arrival_time" => "06:00:00", "departure_time" => "06:00:00"},
               %{"stop_id" => "B", "arrival_time" => "06:05:00", "departure_time" => "06:05:30"},
               %{"stop_id" => "C", "arrival_time" => "06:12:00", "departure_time" => "06:12:00"}
             ]

      assert {:ok, _updated} =
               Gtfs.update_trip(
                 "12c",
                 trip.id,
                 %{trip_headsign: "Loop"},
                 trip.updated_at,
                 context.audit
               )

      assert [log] = trip_logs(context)
      assert log.changed_fields["before"] == snapshots[trip.id]
      assert log.changed_fields["before"]["stop_times"] == snapshots[trip.id]["stop_times"]
    end

    test "twenty trips cost the same number of queries as two", context do
      scope = scope!(context.organization, context.version, "12q")

      two =
        Enum.map(1..2, fn index ->
          trip!(scope, %{trip_id: "12q-#{index}", start_time: "06:0#{index}:00"})
        end)

      twenty =
        Enum.map(1..20, fn index ->
          trip!(scope, %{trip_id: "12q-b#{index}", start_time: "07:00:00"})
        end)

      {two_snapshots, two_count} =
        count_queries(fn ->
          Schedules.trip_audit_snapshots(context.organization.id, context.version.id, two)
        end)

      {twenty_snapshots, twenty_count} =
        count_queries(fn ->
          Schedules.trip_audit_snapshots(context.organization.id, context.version.id, twenty)
        end)

      assert map_size(two_snapshots) == 2
      assert map_size(twenty_snapshots) == 20

      # Stop times, frequencies and timing names: one scoped query each.
      assert two_count == 3
      assert twenty_count == two_count
    end

    test "does not read stop times, frequencies or timing names outside the given scope",
         context do
      other_organization = organization_fixture()
      other_version = gtfs_version_fixture(other_organization.id)
      second_version = gtfs_version_fixture(context.organization.id)

      local =
        trip!(scope!(context.organization, context.version, "12m", timing_name: "In scope"), %{
          trip_id: "12m-0-0600",
          start_time: "06:00:00"
        })

      other_org_scope = scope!(other_organization, other_version, "12n")
      other_org_trip = trip!(other_org_scope, %{trip_id: "12n-0-0600", state: "custom"})

      frequency_fixture(other_organization.id, other_version.id, other_org_trip.trip_id, %{
        start_time: "09:00:00"
      })

      second_version_scope =
        scope!(context.organization, second_version, "12p", timing_name: "Second version")

      second_version_trip =
        trip!(second_version_scope, %{trip_id: "12p-0-0600", start_time: "06:00:00"})

      snapshots =
        Schedules.trip_audit_snapshots(context.organization.id, context.version.id, [
          local,
          other_org_trip,
          second_version_trip
        ])

      # The given scope's own rows are read.
      assert snapshots[local.id]["timing_name"] == "In scope"
      assert snapshots[local.id]["stop_time_count"] == 3

      # The other organization's trip of the same shape contributes nothing: its
      # natural trip ID is absent from this organization and version.
      assert snapshots[other_org_trip.id]["trip_id"] == "12n-0-0600"
      assert snapshots[other_org_trip.id]["stop_time_count"] == 0
      assert snapshots[other_org_trip.id]["stop_times"] == []
      assert snapshots[other_org_trip.id]["frequencies"] == []
      assert snapshots[other_org_trip.id]["start_time"] == nil

      # The second version's trip keeps its own timing name out of this version.
      assert snapshots[second_version_trip.id]["stop_time_count"] == 0
      assert snapshots[second_version_trip.id]["timing_name"] == nil
    end
  end

  defp audit_context(organization, version, actor) do
    %AuditContext{
      organization_id: organization.id,
      gtfs_version_id: version.id,
      station_stop_id: nil,
      actor_id: actor.id,
      actor_email: actor.email
    }
  end

  defp scope!(organization, version, route_id, attrs \\ %{}) do
    attrs = Map.new(attrs)
    route_fixture(organization.id, version.id, %{route_id: route_id})
    service = "svc_#{System.unique_integer([:positive])}"
    calendar_fixture(organization.id, version.id, %{service_id: service})

    bundle =
      schedule_pattern_fixture(organization.id, version.id, %{
        route_id: route_id,
        timing_name: Map.get(attrs, :timing_name, "Standard"),
        stops: Map.get(attrs, :stops, [{"A", 0, 0, 1}, {"B", 300, 330, 1}, {"C", 720, 720, 1}])
      })

    %{
      organization: organization,
      version: version,
      route_id: route_id,
      service: service,
      bundle: bundle
    }
  end

  defp trip!(scope, attrs) do
    schedule_trip_fixture(
      scope.organization.id,
      scope.version.id,
      scope.route_id,
      scope.bundle,
      Map.merge(%{service_id: scope.service}, Map.new(attrs))
    )
    |> Map.fetch!(:trip)
  end

  defp trip_logs(context) do
    Repo.all(
      from(l in ChangeLog,
        where: l.organization_id == ^context.organization.id and l.entity_type == "trip",
        order_by: [asc: l.entity_external_id, asc: l.inserted_at]
      )
    )
  end

  # Ecto emits repo telemetry in the process that ran the query, so counting only
  # the events this test process sees keeps other tests' queries out.
  defp count_queries(fun) do
    test_pid = self()
    handler_id = "audit-snapshots-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler_id,
      [:gtfs_planner, :repo, :query],
      fn _event, _measurements, _metadata, pid ->
        if self() == pid, do: send(pid, {:audit_snapshot_query, handler_id})
      end,
      test_pid
    )

    try do
      {fun.(), drain_queries(handler_id, 0)}
    after
      :telemetry.detach(handler_id)
    end
  end

  defp drain_queries(handler_id, count) do
    receive do
      {:audit_snapshot_query, ^handler_id} -> drain_queries(handler_id, count + 1)
    after
      0 -> count
    end
  end
end
