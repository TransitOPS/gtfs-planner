defmodule GtfsPlanner.Gtfs.StopEditingMakeStationTest do
  @moduledoc """
  `StopEditing.make_station/3` (EV-22, AC-21).

  The operation is only safe because of what it does *not* do: the stop keeps
  its GTFS ID, so every stop time, transfer and pattern occurrence that names it
  still names it. That is the assertion these cases are built around — a command
  that "helpfully" replaced the stop with the station would produce a cleaner
  station and a feed with no timetables.

  The refusals are the other half. A bay is not a station and a stop with
  children already is one, whatever its `location_type` says.
  """

  use ExUnit.Case, async: false

  import Ecto.Query
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.AdvancedBlockingFixtures
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias Ecto.Adapters.SQL.Sandbox
  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Accounts.User
  alias GtfsPlanner.Accounts.UserOrgMembership
  alias GtfsPlanner.Gtfs.AuditContext
  alias GtfsPlanner.Gtfs.ChangeLog
  alias GtfsPlanner.Gtfs.Stop
  alias GtfsPlanner.Gtfs.StopEditing
  alias GtfsPlanner.Gtfs.StopTime
  alias GtfsPlanner.Organizations
  alias GtfsPlanner.Organizations.Organization
  alias GtfsPlanner.Repo

  setup do
    fixture = staged_fixture()

    on_exit(fn -> cleanup_fixture(fixture) end)

    {:ok, fixture: fixture}
  end

  describe "making a station" do
    test "creates the station at the stop's coordinates and makes the stop its bay", context do
      fixture = context.fixture

      assert {:ok, result} = make_station_at(fixture, "1434", "Newport City Hall", "A")

      station = result.station
      bay = result.stop

      assert station.stop_id == "station_newport_city_hall"
      assert station.location_type == 1
      assert station.stop_name == "Newport City Hall"

      # The station stands where the stop stood. An editor turning one stop into
      # a station is describing a place, not moving it.
      assert Decimal.equal?(station.stop_lat, stop_id(fixture, "1434").stop_lat)
      assert Decimal.equal?(station.stop_lon, stop_id(fixture, "1434").stop_lon)

      assert bay.stop_id == "1434"
      assert bay.parent_station == "station_newport_city_hall"
      assert bay.platform_code == "A"
      assert bay.stop_name == "Newport City Hall, Bay A"

      # Read back from the database rather than from the returned structs: a
      # write that was rolled back still returns the struct it was going to
      # write.
      assert unboxed(fn -> reload(fixture, "1434").parent_station end) ==
               "station_newport_city_hall"

      assert unboxed(fn -> Repo.get_by!(Stop, stop_id: "station_newport_city_hall") end)
    end

    test "the bay keeps its stop ID and everything that names it", context do
      fixture = context.fixture

      unboxed(fn ->
        trip_times(fixture, "T-1", [{"1434", 1}, {"1500", 2}])

        transfer_fixture(fixture.organization.id, fixture.version.id, %{
          from_stop_id: "1434",
          to_stop_id: "1500",
          min_transfer_time: 240
        })
      end)

      assert {:ok, _result} = make_station_at(fixture, "1434", "Newport City Hall", "A")

      # Every row still names 1434. A replace would have moved them all and lost
      # the stop's identity in the process.
      assert unboxed(fn ->
               Repo.aggregate(
                 from(t in StopTime,
                   where: t.stop_id == "1434" and t.organization_id == ^fixture.organization.id
                 ),
                 :count
               )
             end) == 1

      assert unboxed(fn ->
               Repo.exists?(
                 from t in GtfsPlanner.Gtfs.Transfer,
                   where:
                     t.from_stop_id == "1434" and
                       t.organization_id == ^fixture.organization.id
               )
             end)
    end

    test "a second station with the same name gets a unique ID", context do
      fixture = context.fixture

      assert {:ok, first} = make_station_at(fixture, "1434", "Newport City Hall", "A")
      assert first.station.stop_id == "station_newport_city_hall"

      # A different stop, same name: the second station is a real place with the
      # same name, so it gets its own ID rather than overwriting or refusing.
      assert {:ok, second} = make_station_at(fixture, "1500", "Newport City Hall", "B")
      assert second.station.stop_id == "station_newport_city_hall_2"
    end

    test "both stops and the change are recorded", context do
      fixture = context.fixture

      assert {:ok, _result} = make_station_at(fixture, "1434", "Newport City Hall", "A")

      logged =
        unboxed(fn ->
          Repo.all(
            from log in ChangeLog,
              where: log.organization_id == ^fixture.organization.id,
              order_by: [asc: log.inserted_at, asc: log.entity_external_id],
              select: {log.action, log.entity_external_id}
          )
        end)

      # INV-2: the station's creation and the bay's re-parenting commit together,
      # so a feed never holds a bay naming a station nobody wrote down.
      assert {"created", "station_newport_city_hall"} in logged
      assert {"updated", "1434"} in logged
    end
  end

  describe "refusals" do
    test "a bay is refused :child", context do
      fixture = context.fixture

      unboxed(fn ->
        stop_fixture(fixture.organization.id, fixture.version.id, %{
          stop_id: "ST-1",
          stop_name: "Depot",
          location_type: 1,
          stop_lat: Decimal.from_float(44.6250),
          stop_lon: Decimal.from_float(-124.0530)
        })

        stop_fixture(fixture.organization.id, fixture.version.id, %{
          stop_id: "CHILD-1",
          stop_name: "Bay 1",
          platform_code: "A",
          parent_station: "ST-1",
          stop_lat: Decimal.from_float(44.6211),
          stop_lon: Decimal.from_float(-124.0530)
        })
      end)

      assert {:error, :child} =
               make_station_at(fixture, "CHILD-1", "Newport City Hall", "A")

      # Nothing was written: no station, and the bay still points at its own.
      refute unboxed(fn -> Repo.exists?(from s in Stop, where: like(s.stop_id, "station_%")) end)

      assert unboxed(fn -> reload(fixture, "CHILD-1").parent_station end) == "ST-1"
    end

    test "a stop that already has children is refused :has_children", context do
      fixture = context.fixture

      unboxed(fn ->
        # 1434 is a plain stop here, so the refusal is asked of the children
        # rather than of the location type — which is the point: an imported feed
        # can leave a stop with bays and no station type.
        stop_fixture(fixture.organization.id, fixture.version.id, %{
          stop_id: "CHILD-1",
          stop_name: "Bay 1",
          platform_code: "A",
          parent_station: "1434",
          stop_lat: Decimal.from_float(44.6211),
          stop_lon: Decimal.from_float(-124.0530)
        })
      end)

      assert {:error, :has_children} =
               make_station_at(fixture, "1434", "Newport City Hall", "A")

      refute unboxed(fn -> Repo.exists?(from s in Stop, where: like(s.stop_id, "station_%")) end)
    end

    test "a name that yields no station ID is refused", context do
      fixture = context.fixture

      assert {:error, :invalid_station} = make_station_at(fixture, "1434", "  ", "A")
    end

    test "a stop the actor may not edit is forbidden and writes nothing", context do
      fixture = context.fixture

      stranger =
        unboxed(fn -> user_fixture(%{email: "station-forbid-#{stamp()}@example.com"}) end)

      before = unboxed(fn -> snapshot(fixture) end)

      assert {:error, :forbidden} =
               unboxed(fn ->
                 StopEditing.make_station(
                   stop_id(fixture, "1434").id,
                   %{"station_name" => "Newport City Hall", "platform_code" => "A"},
                   %{fixture.audit | actor_id: stranger.id}
                 )
               end)

      assert unboxed(fn -> snapshot(fixture) end) == before
    end
  end

  # --- drivers

  defp make_station_at(fixture, stop_id, station_name, platform_code) do
    unboxed(fn ->
      StopEditing.make_station(
        stop_id(fixture, stop_id).id,
        %{"station_name" => station_name, "platform_code" => platform_code},
        fixture.audit
      )
    end)
  end

  defp stop_id(fixture, stop_id) do
    case Map.fetch(fixture.stops, stop_id) do
      {:ok, stop} -> stop
      :error -> Repo.get_by!(Stop, stop_id: stop_id, gtfs_version_id: fixture.version.id)
    end
  end

  defp reload(fixture, stop_id) do
    Repo.get_by!(Stop, stop_id: stop_id, gtfs_version_id: fixture.version.id)
  end

  defp trip_times(fixture, trip_id, stop_ids) do
    trip_fixture(fixture.organization.id, fixture.version.id, trip_id, %{
      trip_id: trip_id,
      service_id: "WEEKDAYS"
    })

    Enum.each(stop_ids, fn {stop_id, sequence} ->
      stop_time_fixture(fixture.organization.id, fixture.version.id, trip_id, stop_id, %{
        stop_sequence: sequence,
        arrival_time: "08:0#{sequence}:00",
        departure_time: "08:0#{sequence}:00"
      })
    end)
  end

  # Stops, their timetables and the history: the three things this command writes
  # or leaves alone.
  defp snapshot(fixture) do
    unboxed(fn ->
      scope = [fixture.organization.id, fixture.version.id]

      %{
        stops:
          Repo.all(
            from s in Stop,
              where: s.organization_id in ^scope,
              order_by: s.stop_id,
              select: {s.id, s.stop_id, s.parent_station, s.platform_code, s.stop_name}
          ),
        stop_times:
          Repo.all(
            from t in StopTime,
              where: t.organization_id in ^scope,
              order_by: field(t, :id),
              select: {t.id, t.stop_id}
          ),
        logs: Repo.all(from l in ChangeLog, select: {l.id, l.entity_external_id})
      }
    end)
  end

  # --- staging

  defp staged_fixture do
    unboxed(fn ->
      organization = organization_fixture(%{alias: "stop-station-#{stamp()}"})
      version = gtfs_version_fixture(organization.id)
      actor = add_actor(organization.id)

      audit = %AuditContext{
        organization_id: organization.id,
        gtfs_version_id: version.id,
        actor_id: actor.id,
        actor_email: actor.email
      }

      stops =
        Map.new(
          [{"1434", "Main St"}, {"1500", "Harbour Way"}],
          fn {id, name} ->
            {id,
             stop_fixture(organization.id, version.id, %{
               stop_id: id,
               stop_name: name,
               stop_lat: Decimal.from_float(44.6200),
               stop_lon: Decimal.from_float(-124.0530)
             })}
          end
        )

      calendar_fixture(organization.id, version.id, %{service_id: "WEEKDAYS"})

      %{
        organization: organization,
        version: version,
        actor: actor,
        audit: audit,
        stops: stops
      }
    end)
  end

  defp add_actor(organization_id) do
    actor = user_fixture(%{email: "stop-station-#{stamp()}@example.com"})

    {:ok, _membership} =
      Accounts.create_user_org_membership(%{
        user_id: actor.id,
        organization_id: organization_id,
        roles: ["pathways_studio_editor"]
      })

    actor
  end

  defp unboxed(fun), do: Sandbox.unboxed_run(Repo, fun)

  defp stamp, do: System.system_time(:nanosecond)

  @cleanup_tables [
    ChangeLog,
    StopTime,
    Stop,
    GtfsPlanner.Gtfs.Transfer,
    GtfsPlanner.Gtfs.Trip,
    GtfsPlanner.Gtfs.Calendar
  ]

  defp cleanup_fixture(fixture) do
    unboxed(fn ->
      scope = [fixture.organization.id, fixture.version.id]

      Enum.each(@cleanup_tables, fn table ->
        Repo.delete_all(
          from row in table,
            where: row.organization_id in ^scope or row.gtfs_version_id in ^scope
        )
      end)

      Repo.delete_all(
        from m in UserOrgMembership, where: m.organization_id == ^fixture.organization.id
      )

      Repo.delete_all(from o in Organization, where: o.id == ^fixture.organization.id)

      # An unboxed test commits the users its actor and stranger fixtures
      # created. Deleting the organization removes the membership but not the
      # user, and a leftover user breaks the first-administrator tests, which
      # need a database with no committed users.
      Repo.delete_all(
        from u in User,
          where: like(u.email, "station-forbid-%") or like(u.email, "stop-station-%")
      )
    end)
  end
end
