defmodule GtfsPlanner.HomeTest do
  use GtfsPlanner.DataCase, async: false

  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.ChangeLog
  alias GtfsPlanner.Gtfs.StationEditingStatus
  alias GtfsPlanner.Home
  alias GtfsPlanner.HomeSourceStub
  alias GtfsPlanner.Organizations
  alias GtfsPlanner.Repo

  test "organization_admins lists only the organization's active admins, sorted" do
    organization = organization_fixture()

    editor = user_fixture()
    deactivated_admin = user_fixture()
    alpha_admin = user_fixture(%{email: "alpha-admin@example.test"})
    zulu_admin = user_fixture(%{email: "zulu-admin@example.test"})

    {:ok, _} =
      Organizations.add_user_to_organization(editor.id, organization.id, [
        "pathways_studio_editor"
      ])

    {:ok, _} =
      Organizations.add_user_to_organization(deactivated_admin.id, organization.id, [
        "pathways_studio_admin"
      ])

    {:ok, _} =
      Organizations.add_user_to_organization(zulu_admin.id, organization.id, [
        "pathways_studio_admin"
      ])

    {:ok, _} =
      Organizations.add_user_to_organization(alpha_admin.id, organization.id, [
        "pathways_studio_admin"
      ])

    # Deactivated last, so the organization always keeps another active admin.
    {:ok, _} =
      Organizations.deactivate_user_in_organization(
        alpha_admin,
        deactivated_admin.id,
        organization.id
      )

    other_organization = organization_fixture()
    foreign_admin = user_fixture()

    {:ok, _} =
      Organizations.add_user_to_organization(foreign_admin.id, other_organization.id, [
        "pathways_studio_admin"
      ])

    assert Home.organization_admins(organization.id) == [
             "alpha-admin@example.test",
             "zulu-admin@example.test"
           ]
  end

  test "member_count counts only active members" do
    organization = organization_fixture()

    active_editor = user_fixture()
    active_admin = user_fixture()
    deactivated_member = user_fixture()

    {:ok, _} =
      Organizations.add_user_to_organization(active_editor.id, organization.id, [
        "pathways_studio_editor"
      ])

    {:ok, _} =
      Organizations.add_user_to_organization(active_admin.id, organization.id, [
        "pathways_studio_admin"
      ])

    {:ok, _} = Organizations.add_user_to_organization(deactivated_member.id, organization.id, [])

    {:ok, _} =
      Organizations.deactivate_user_in_organization(
        active_admin,
        deactivated_member.id,
        organization.id
      )

    assert Home.member_count(organization.id) == 2
  end

  test "organization_count counts the stored organizations" do
    before = Home.organization_count()

    organization_fixture()
    organization_fixture()

    assert Home.organization_count() == before + 2
  end

  test "resume returns the team scope for a user without changes" do
    organization = organization_fixture()
    gtfs_version = gtfs_version_fixture(organization.id)

    route_fixture(organization.id, gtfs_version.id, %{route_id: "R1", route_short_name: "1"})

    teammate = user_fixture()
    member = user_fixture()

    insert_change_log(organization, gtfs_version, %{
      entity_external_id: "TRIP-1",
      actor_id: teammate.id,
      actor_email: teammate.email,
      changed_fields: %{
        "before" => nil,
        "after" => %{"route_id" => "R1", "service_id" => "weekday"}
      },
      inserted_at: ~U[2026-09-20 12:00:00.000000Z]
    })

    assert %{scope: :team, items: [item]} =
             Home.resume(organization.id, gtfs_version.id, member.id)

    assert item.actor_email == teammate.email
    assert item.kind == :schedules
    assert item.title == "Test Route"
    assert item.local_at == ~N[2026-09-20 12:00:00.000000]
  end

  test "station_board returns each station's line count, zero when no platform is served" do
    organization = organization_fixture()
    gtfs_version = gtfs_version_fixture(organization.id)
    level = level_fixture(organization.id, gtfs_version.id)

    station =
      stop_fixture(organization.id, gtfs_version.id, %{
        stop_id: "STA",
        stop_name: "Alpha",
        location_type: 1
      })

    unserved_station =
      stop_fixture(organization.id, gtfs_version.id, %{
        stop_id: "STB",
        stop_name: "Beta",
        location_type: 1
      })

    first_platform = child_platform(organization, gtfs_version, "P1", station, level)
    second_platform = child_platform(organization, gtfs_version, "P2", station, level)

    route_five =
      route_fixture(organization.id, gtfs_version.id, %{route_id: "R5", route_short_name: "5"})

    route_seven =
      route_fixture(organization.id, gtfs_version.id, %{route_id: "R7", route_short_name: "7"})

    serve_platform(organization, gtfs_version, route_five, "T5", first_platform.stop_id)
    serve_platform(organization, gtfs_version, route_seven, "T7", second_platform.stop_id)

    assert %{stations: stations, lines: lines} =
             Home.station_board(organization.id, gtfs_version.id)

    assert Enum.map(stations, & &1.stop_id) == ["STA", "STB"]
    assert Enum.map(stations, & &1.id) == [station.id, unserved_station.id]
    assert lines == %{"STA" => 2, "STB" => 0}
  end

  test "station_board adds each station's last edit on the agency-local clock" do
    organization = organization_fixture()
    gtfs_version = gtfs_version_fixture(organization.id)

    agency_fixture(organization.id, gtfs_version.id, %{agency_timezone: "America/New_York"})

    stop_fixture(organization.id, gtfs_version.id, %{stop_id: "STA", location_type: 1})
    stop_fixture(organization.id, gtfs_version.id, %{stop_id: "STB", location_type: 1})

    insert_change_log(organization, gtfs_version, %{
      entity_type: "stop",
      station_stop_id: "STA",
      inserted_at: ~U[2026-09-20 02:30:00.000000Z]
    })

    assert %{stations: [edited, never_edited]} =
             Home.station_board(organization.id, gtfs_version.id)

    assert edited.last_edited_at == ~U[2026-09-20 02:30:00.000000Z]
    assert edited.last_edited_local == ~N[2026-09-19 22:30:00.000000]
    assert never_edited.last_edited_at == nil
    assert never_edited.last_edited_local == nil
  end

  test "station_editors returns each editor's started_at in the display zone" do
    organization = organization_fixture()
    gtfs_version = gtfs_version_fixture(organization.id)

    station =
      stop_fixture(organization.id, gtfs_version.id, %{
        stop_id: "STA",
        stop_name: "Alpha",
        location_type: 1
      })

    editor = user_fixture()

    assert {:ok, status} =
             Gtfs.set_station_editing_status(organization.id, gtfs_version.id, station, editor)

    # Pin the persisted time so the localized assertion does not depend on the clock.
    {1, _} =
      from(s in StationEditingStatus, where: s.id == ^status.id)
      |> Repo.update_all(set: [started_at: ~U[2026-09-20 10:00:00.000000Z]])

    assert [entry] = Home.station_editors(organization.id, gtfs_version.id)
    assert entry.station_stop_id == "STA"
    assert entry.station_name == "Alpha"
    assert entry.email == editor.email
    assert entry.started_at == ~N[2026-09-20 10:00:00.000000]
  end

  test "the home source stub delegates every read to GtfsPlanner.Home" do
    organization = organization_fixture()
    gtfs_version = gtfs_version_fixture(organization.id)
    admin = user_fixture()

    {:ok, _} =
      Organizations.add_user_to_organization(admin.id, organization.id, [
        "pathways_studio_admin"
      ])

    assert HomeSourceStub.organization_admins(organization.id) == [admin.email]
    assert HomeSourceStub.member_count(organization.id) == 1
    assert HomeSourceStub.organization_count() == Home.organization_count()

    assert HomeSourceStub.resume(organization.id, gtfs_version.id, admin.id) ==
             Home.resume(organization.id, gtfs_version.id, admin.id)

    assert HomeSourceStub.station_board(organization.id, gtfs_version.id) ==
             Home.station_board(organization.id, gtfs_version.id)

    assert HomeSourceStub.station_statuses(organization.id, gtfs_version.id, []) == %{}
    assert HomeSourceStub.station_editors(organization.id, gtfs_version.id) == []

    assert HomeSourceStub.planner_status(organization.id, gtfs_version.id) ==
             Home.planner_status(organization.id, gtfs_version.id)

    assert HomeSourceStub.pathways_attention(organization.id, gtfs_version.id) ==
             Home.pathways_attention(organization.id, gtfs_version.id)

    assert HomeSourceStub.check_and_share(organization.id, gtfs_version.id, :planner) ==
             Home.check_and_share(organization.id, gtfs_version.id, :planner)
  end

  test "the home source stub raises only for the functions named in :home_failing_functions" do
    organization = organization_fixture()
    gtfs_version = gtfs_version_fixture(organization.id)
    user = user_fixture()

    with_failing_functions([:resume], fn ->
      assert_raise RuntimeError, fn ->
        HomeSourceStub.resume(organization.id, gtfs_version.id, user.id)
      end

      assert HomeSourceStub.member_count(organization.id) == 0
      assert HomeSourceStub.station_editors(organization.id, gtfs_version.id) == []
    end)
  end

  defp insert_change_log(organization, gtfs_version, attrs) do
    row =
      Map.merge(
        %{
          id: Ecto.UUID.generate(),
          entity_type: "trip",
          entity_id: Ecto.UUID.generate(),
          entity_external_id: Ecto.UUID.generate(),
          station_stop_id: nil,
          actor_id: Ecto.UUID.generate(),
          actor_email: "teammate@example.test",
          snapshot: nil,
          changed_fields: nil,
          action: "updated",
          organization_id: organization.id,
          gtfs_version_id: gtfs_version.id,
          inserted_at: ~U[2026-09-01 12:00:00.000000Z]
        },
        attrs
      )

    Repo.insert_all(ChangeLog, [row])
  end

  defp child_platform(organization, gtfs_version, stop_id, station, level) do
    stop_fixture(organization.id, gtfs_version.id, %{
      stop_id: stop_id,
      stop_name: "Child stop #{stop_id}",
      location_type: 0,
      parent_station: station.stop_id,
      level_id: level.level_id
    })
  end

  defp serve_platform(organization, gtfs_version, route, trip_id, stop_id) do
    trip = trip_fixture(organization.id, gtfs_version.id, route.route_id, %{trip_id: trip_id})

    stop_time_fixture(organization.id, gtfs_version.id, trip.trip_id, stop_id)
  end

  defp with_failing_functions(functions, fun) do
    previous = Application.get_env(:gtfs_planner, :home_failing_functions)
    Application.put_env(:gtfs_planner, :home_failing_functions, functions)

    on_exit(fn ->
      if is_nil(previous) do
        Application.delete_env(:gtfs_planner, :home_failing_functions)
      else
        Application.put_env(:gtfs_planner, :home_failing_functions, previous)
      end
    end)

    fun.()
  end
end
