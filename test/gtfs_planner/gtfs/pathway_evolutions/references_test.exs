defmodule GtfsPlanner.Gtfs.PathwayEvolutions.ReferencesTest do
  @moduledoc """
  Native-calendar reference guards through the ordinary `Gtfs` facade
  (`review_calendar_change/3`, `apply_calendar_change/3`, `calendar_usage/3`):
  a service referenced by closures keeps a native `calendars`/`calendar_dates`
  row under every planned change, closure usage joins calendar usage without
  changing trip counts, and closure usage changes move the calendar source
  fingerprint. Expectations are hand-authored from the acceptance cases
  (AC-9, AC-10).
  """
  use GtfsPlanner.DataCase

  import Ecto.Query
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.AuditContext
  alias GtfsPlanner.Gtfs.Calendar
  alias GtfsPlanner.Gtfs.CalendarDate
  alias GtfsPlanner.Gtfs.PathwayEvolutions

  setup do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    actor = user_fixture()
    membership = organization_membership_fixture(actor, organization)

    level_fixture(organization.id, version.id, %{level_id: "L_STREET", level_index: 0.0})
    level_fixture(organization.id, version.id, %{level_id: "L_PLAT", level_index: -1.0})

    stop_fixture(organization.id, version.id, %{stop_id: "STN_1", location_type: 1})
    stop_fixture(organization.id, version.id, %{stop_id: "STN_2", location_type: 1})

    stop_fixture(organization.id, version.id, %{
      stop_id: "ENT_1",
      location_type: 2,
      parent_station: "STN_1",
      level_id: "L_STREET"
    })

    stop_fixture(organization.id, version.id, %{
      stop_id: "PLAT_1",
      location_type: 0,
      parent_station: "STN_1",
      level_id: "L_PLAT"
    })

    stop_fixture(organization.id, version.id, %{
      stop_id: "BA_1",
      location_type: 4,
      parent_station: "PLAT_1",
      level_id: "L_PLAT"
    })

    stop_fixture(organization.id, version.id, %{
      stop_id: "PLAT_2",
      location_type: 0,
      parent_station: "STN_2",
      level_id: "L_PLAT"
    })

    stop_fixture(organization.id, version.id, %{stop_id: "OUT_A", location_type: 3})
    stop_fixture(organization.id, version.id, %{stop_id: "OUT_B", location_type: 3})

    pathway_fixture(organization.id, version.id, "ENT_1", "PLAT_1", %{
      pathway_id: "PW_ENTRY",
      pathway_mode: 2
    })

    pathway_fixture(organization.id, version.id, "PLAT_1", "BA_1", %{
      pathway_id: "PW_BA",
      pathway_mode: 1
    })

    pathway_fixture(organization.id, version.id, "PLAT_1", "PLAT_2", %{
      pathway_id: "PW_SHARED",
      pathway_mode: 1
    })

    pathway_fixture(organization.id, version.id, "OUT_A", "OUT_B", %{
      pathway_id: "PW_LOST",
      pathway_mode: 1
    })

    calendar_date_fixture(organization.id, version.id, %{
      service_id: "SVC_DATES",
      date: ~D[2026-07-04],
      exception_type: 1
    })

    calendar_date_fixture(organization.id, version.id, %{
      service_id: "SVC_FREE",
      date: ~D[2026-07-04],
      exception_type: 1
    })

    %{
      organization: organization,
      version: version,
      actor: actor,
      membership: membership,
      audit: %AuditContext{
        organization_id: organization.id,
        gtfs_version_id: version.id,
        station_stop_id: "STN_1",
        actor_id: actor.id,
        actor_email: actor.email
      }
    }
  end

  test "calendar deletion is refused while closures reference the service and keeps its rows",
       context do
    # A review token issued before the closure exists proves the apply boundary
    # cannot commit the deletion once usage changes.
    source_pre = source!(context, "SVC_DATES")

    assert {:ok, pre_review} =
             review(context, {:delete, "SVC_DATES"}, source_pre)

    create_closure!(context, "PW_ENTRY", "SVC_DATES")

    assert {:error, :stale_review} =
             apply_change(context, {:delete, "SVC_DATES"}, pre_review.fingerprint)

    source = source!(context, "SVC_DATES")

    assert {:error, {:closures_in_use, usage}} =
             review(context, {:delete, "SVC_DATES"}, source)

    assert usage.closure_count == 1
    assert usage.pathway_ids == ["PW_ENTRY"]
    assert usage.trip_count == 0
    assert usage.route_ids == []
    assert usage.routes == []
    assert usage.closure_paths == [%{pathway_id: "PW_ENTRY", station_stop_ids: ["STN_1"]}]

    assert Enum.count(exception_rows(context, "SVC_DATES")) == 1
    assert Enum.count(closure_rows(context, "SVC_DATES")) == 1
  end

  test "closure usage joins trip usage exactly and the trip tuple still blocks delete",
       context do
    route = route_fixture(context.organization.id, context.version.id)

    trip_fixture(context.organization.id, context.version.id, route.route_id, %{
      service_id: "SVC_DATES"
    })

    create_closure!(context, "PW_ENTRY", "SVC_DATES")

    assert {:ok, usage} =
             Gtfs.calendar_usage(context.organization.id, context.version.id, "SVC_DATES")

    assert usage.trip_count == 1
    assert usage.route_ids == [route.route_id]
    assert usage.routes == [%{route_id: route.route_id, trip_count: 1}]
    assert usage.closure_count == 1
    assert usage.pathway_ids == ["PW_ENTRY"]

    # With trips and closures both present the existing trip tuple is retained.
    assert {:error, {:in_use, 1, [route_id]}} =
             review(context, {:delete, "SVC_DATES"}, source!(context, "SVC_DATES"))

    assert route_id == route.route_id

    [closure] = closure_rows(context, "SVC_DATES")

    assert {:ok, _} =
             Gtfs.delete_pathway_evolution(
               closure.id,
               PathwayEvolutions.fingerprint(closure),
               context.audit
             )

    assert {:ok, after_usage} =
             Gtfs.calendar_usage(context.organization.id, context.version.id, "SVC_DATES")

    assert after_usage.closure_count == 0
    assert after_usage.pathway_ids == []
    assert after_usage.closure_paths == []
    assert after_usage.trip_count == 1
    assert after_usage.route_ids == [route.route_id]

    assert {:error, {:in_use, 1, [^route_id]}} =
             review(context, {:delete, "SVC_DATES"}, source!(context, "SVC_DATES"))
  end

  test "removing the last date of a referenced dates-only calendar is refused", context do
    source_pre = source!(context, "SVC_DATES")

    assert {:ok, pre_review} =
             review(context, {:remove_exceptions, "SVC_DATES", [~D[2026-07-04]]}, source_pre)

    create_closure!(context, "PW_ENTRY", "SVC_DATES")

    assert {:error, :stale_review} =
             apply_change(
               context,
               {:remove_exceptions, "SVC_DATES", [~D[2026-07-04]]},
               pre_review.fingerprint
             )

    assert Enum.count(exception_rows(context, "SVC_DATES")) == 1

    assert {:error, {:closure_reference_lost, usage}} =
             review(
               context,
               {:remove_exceptions, "SVC_DATES", [~D[2026-07-04]]},
               source!(context, "SVC_DATES")
             )

    assert usage.closure_count == 1
    assert usage.pathway_ids == ["PW_ENTRY"]
    assert usage.closure_paths == [%{pathway_id: "PW_ENTRY", station_stop_ids: ["STN_1"]}]

    assert Enum.count(exception_rows(context, "SVC_DATES")) == 1
    assert Enum.count(closure_rows(context, "SVC_DATES")) == 1
  end

  test "an empty weekly-to-dates-only conversion is refused while closures reference the service",
       context do
    create_empty_weekly!(context, "SVC_WEEK")
    create_closure!(context, "PW_BA", "SVC_WEEK")

    assert {:error, {:closure_reference_lost, usage}} =
             review(
               context,
               {:convert, "SVC_WEEK", :dates_only, %{}},
               source!(context, "SVC_WEEK")
             )

    assert usage.closure_count == 1
    assert usage.pathway_ids == ["PW_BA"]
    assert usage.closure_paths == [%{pathway_id: "PW_BA", station_stop_ids: ["STN_1"]}]

    assert Enum.count(weekly_rows(context, "SVC_WEEK")) == 1
    assert Enum.count(exception_rows(context, "SVC_WEEK")) == 1
    assert Enum.count(closure_rows(context, "SVC_WEEK")) == 1
  end

  test "a removal exception that empties active dates proceeds with existing warnings and unrelated calendars stay editable",
       context do
    calendar_fixture(context.organization.id, context.version.id, %{
      service_id: "SVC_WEEK",
      start_date: ~D[2026-01-05],
      end_date: ~D[2026-01-05],
      monday: 1
    })

    create_closure!(context, "PW_ENTRY", "SVC_WEEK")

    command = {:put_exceptions, "SVC_WEEK", [~D[2026-01-05]], :removed}

    assert {:ok, reviewed} = review(context, command, source!(context, "SVC_WEEK"))

    assert Enum.any?(
             reviewed.warnings,
             &(&1.reason == :no_service and &1.service_id == "SVC_WEEK")
           )

    assert {:ok, _result} = apply_change(context, command, reviewed.fingerprint)

    reloaded = source!(context, "SVC_WEEK")
    assert reloaded.active_dates == []
    assert Enum.count(weekly_rows(context, "SVC_WEEK")) == 1
    assert Enum.count(exception_rows(context, "SVC_WEEK")) == 1
    assert Enum.count(closure_rows(context, "SVC_WEEK")) == 1

    # An unrelated service without closures keeps its ordinary edit rights even
    # while another service is closure-protected.
    free_command = {:remove_exceptions, "SVC_FREE", [~D[2026-07-04]]}

    assert {:ok, free_review} = review(context, free_command, source!(context, "SVC_FREE"))
    assert {:ok, _} = apply_change(context, free_command, free_review.fingerprint)
    assert exception_rows(context, "SVC_FREE") == []
  end

  test "closure usage moves the calendar fingerprint and joins list summaries with exact pathway IDs",
       context do
    route = route_fixture(context.organization.id, context.version.id)

    trip_fixture(context.organization.id, context.version.id, route.route_id, %{
      service_id: "SVC_DATES"
    })

    before = source!(context, "SVC_DATES")
    assert before.usage.trip_count == 1
    assert before.usage.closure_count == 0

    assert {:ok, created} =
             Gtfs.create_pathway_evolution(
               %{
                 pathway_id: "PW_SHARED",
                 service_id: "SVC_DATES",
                 start_time: "09:00",
                 end_time: "10:00"
               },
               context.audit
             )

    after_create = source!(context, "SVC_DATES")
    refute after_create.fingerprint == before.fingerprint
    assert after_create.usage.closure_count == 1
    assert after_create.usage.pathway_ids == ["PW_SHARED"]
    assert after_create.usage.trip_count == 1
    assert after_create.usage.route_ids == [route.route_id]

    assert after_create.usage.closure_paths == [
             %{pathway_id: "PW_SHARED", station_stop_ids: ["STN_1", "STN_2"]}
           ]

    assert [%{service_id: "SVC_DATES"} = summary] =
             summaries(context) |> Enum.filter(&(&1.service_id == "SVC_DATES"))

    assert summary.closure_count == 1
    assert summary.pathway_ids == ["PW_SHARED"]
    assert summary.trip_count == 1
    assert summary.fingerprint == after_create.fingerprint

    assert {:ok, _} =
             Gtfs.delete_pathway_evolution(
               created.evolution.id,
               created.fingerprint,
               context.audit
             )

    after_delete = source!(context, "SVC_DATES")
    refute after_delete.fingerprint == after_create.fingerprint
    assert after_delete.usage.closure_count == 0
    assert after_delete.usage.pathway_ids == []
    assert after_delete.usage.closure_paths == []
    assert after_delete.usage.trip_count == 1
  end

  test "closure_paths keeps multi-station links sorted and unresolved ownership as empty",
       context do
    create_closure!(context, "PW_SHARED", "SVC_DATES")
    create_closure!(context, "PW_LOST", "SVC_DATES")

    assert {:ok, usage} =
             Gtfs.calendar_usage(context.organization.id, context.version.id, "SVC_DATES")

    assert usage.closure_count == 2
    assert usage.pathway_ids == ["PW_LOST", "PW_SHARED"]

    assert usage.closure_paths == [
             %{pathway_id: "PW_LOST", station_stop_ids: []},
             %{pathway_id: "PW_SHARED", station_stop_ids: ["STN_1", "STN_2"]}
           ]
  end

  test "a multi-service date change plans every service and keeps referenced native rows",
       context do
    calendar_fixture(context.organization.id, context.version.id, %{
      service_id: "SVC_WEEK",
      start_date: ~D[2026-01-05],
      end_date: ~D[2026-01-05],
      monday: 1
    })

    calendar_date_fixture(context.organization.id, context.version.id, %{
      service_id: "SVC_FREE2",
      date: ~D[2026-02-02],
      exception_type: 1
    })

    create_closure!(context, "PW_ENTRY", "SVC_WEEK")

    command = {:date_change, [~D[2026-01-05]], ["SVC_WEEK"], ["SVC_FREE2"]}

    fingerprints = %{
      "SVC_WEEK" => source!(context, "SVC_WEEK").fingerprint,
      "SVC_FREE2" => source!(context, "SVC_FREE2").fingerprint
    }

    assert {:ok, reviewed} =
             Gtfs.review_calendar_change(command, fingerprints, context.audit)

    assert reviewed.affected_service_ids == ["SVC_FREE2", "SVC_WEEK"]

    assert {:ok, _result} = apply_change(context, command, reviewed.fingerprint)

    # The referenced service keeps its weekly row (a native row) behind the
    # removal exception, so existence-only integrity holds and the closure stays.
    assert Enum.count(weekly_rows(context, "SVC_WEEK")) == 1
    assert Enum.count(exception_rows(context, "SVC_WEEK")) == 1
    assert Enum.count(closure_rows(context, "SVC_WEEK")) == 1
    assert source!(context, "SVC_WEEK").usage.closure_count == 1
  end

  defp review(context, command, payload) do
    Gtfs.review_calendar_change(
      command,
      %{elem(command, 1) => payload.fingerprint},
      context.audit
    )
  end

  defp apply_change(context, command, fingerprint) do
    Gtfs.apply_calendar_change(command, fingerprint, context.audit)
  end

  defp source!(context, service_id) do
    assert {:ok, payload} =
             Gtfs.get_calendar(context.organization.id, context.version.id, service_id)

    payload
  end

  defp summaries(context) do
    assert {:ok, summaries} =
             Gtfs.load_calendar_catalog(context.organization.id, context.version.id)

    summaries
  end

  defp create_closure!(context, pathway_id, service_id) do
    pathway_evolution_fixture(context.organization.id, context.version.id, %{
      pathway_id: pathway_id,
      service_id: service_id
    })
  end

  # A weekly row whose only service day is already removed: native rows exist
  # while the effective active date set is empty.
  defp create_empty_weekly!(context, service_id) do
    calendar_fixture(context.organization.id, context.version.id, %{
      service_id: service_id,
      start_date: ~D[2026-01-05],
      end_date: ~D[2026-01-05],
      monday: 1
    })

    calendar_date_fixture(context.organization.id, context.version.id, %{
      service_id: service_id,
      date: ~D[2026-01-05],
      exception_type: 2
    })
  end

  defp weekly_rows(context, service_id) do
    Repo.all(
      from(c in Calendar,
        where:
          c.organization_id == ^context.organization.id and
            c.gtfs_version_id == ^context.version.id and c.service_id == ^service_id
      )
    )
  end

  defp exception_rows(context, service_id) do
    Repo.all(
      from(d in CalendarDate,
        where:
          d.organization_id == ^context.organization.id and
            d.gtfs_version_id == ^context.version.id and d.service_id == ^service_id
      )
    )
  end

  defp closure_rows(context, service_id) do
    Repo.all(
      from(e in GtfsPlanner.Gtfs.PathwayEvolution,
        where:
          e.organization_id == ^context.organization.id and
            e.gtfs_version_id == ^context.version.id and e.service_id == ^service_id
      )
    )
  end
end
