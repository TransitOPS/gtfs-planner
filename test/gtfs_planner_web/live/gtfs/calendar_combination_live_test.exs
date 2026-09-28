defmodule GtfsPlannerWeb.Gtfs.CalendarCombinationLiveTest do
  @moduledoc """
  LiveView evidence for the calendar selection and the initial Combine calendars drawer.

  Every case drives the ordinary authenticated `/gtfs/:version/calendars` route through the real
  `CalendarsLive` socket and the default `CatalogReadAdapter.Repo`; no private assign is injected
  and no test-only registration exists, so a missing production wiring fails here instead of
  passing against a constructed socket. The review itself is the public
  `Gtfs.review_calendar_change/3` combination command, and the block, transfer and retained-source
  lines come from the concrete package-05 `Blocking` producer over real trips, stop times and
  transfer rows.

  Covered here: exact-ID selection and its pruning rules, the deterministic most-trips default
  destination, the no-op review, the unavailable state when a retained range cannot be read, the
  fact that opening or re-reviewing writes nothing, and the explicit conflict decisions - their
  fieldsets, the refused submission, the consequences each choice produces and the seasonal
  expansion warning. Submission recovery and the applied result are owned by a later step.

  The prepared focused command is deferred to branch review:
  `MIX_ENV=test MIX_TEST_PARTITION=_calendar17 mix test test/gtfs_planner_web/live/gtfs/calendar_combination_live_test.exs`.
  """
  use GtfsPlannerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures
  import GtfsPlanner.GtfsFixtures

  import Ecto.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Accounts.User
  alias GtfsPlanner.Accounts.UserOrgMembership
  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.Agency
  alias GtfsPlanner.Gtfs.AuditContext
  alias GtfsPlanner.Gtfs.Calendar
  alias GtfsPlanner.Gtfs.CalendarAttribute
  alias GtfsPlanner.Gtfs.CalendarDate
  alias GtfsPlanner.Gtfs.ChangeLog
  alias GtfsPlanner.Gtfs.Route
  alias GtfsPlanner.Gtfs.Stop
  alias GtfsPlanner.Gtfs.StopTime
  alias GtfsPlanner.Gtfs.Transfer
  alias GtfsPlanner.Gtfs.Trip
  alias GtfsPlanner.Repo
  alias GtfsPlanner.Versions.GtfsVersion
  alias GtfsPlannerWeb.Gtfs.CalendarComponents

  setup do
    organization = organization_fixture()
    user = user_fixture()

    Accounts.create_user_org_membership(%{
      user_id: user.id,
      organization_id: organization.id,
      roles: ["pathways_studio_editor"]
    })

    %{user: user, organization: organization, version: gtfs_version_fixture(organization.id)}
  end

  # The first paint defers its read: the socket sends itself `:load_calendars`, so this waits for
  # the mailbox to be handled instead of sleeping and then renders the settled list.
  defp loaded(view) do
    _ = :sys.get_state(view.pid)
    render(view)
  end

  defp list_path(version, query \\ %{}) do
    case URI.encode_query(query) do
      "" -> "/gtfs/#{version.id}/calendars"
      encoded -> "/gtfs/#{version.id}/calendars?#{encoded}"
    end
  end

  defp editor(conn, user, organization), do: log_in_user(conn, user, organization: organization)

  # The fixtures derive their dates from the same agency-local today the read resolves, so a
  # status or range assertion cannot depend on the day the suite runs.
  defp postgres_local_today(timezone) do
    %{rows: [[%Date{} = date]]} = Repo.query!("SELECT (now() AT TIME ZONE $1)::date", [timezone])

    date
  end

  # One coherent combination scenario: a Saturday destination that keeps its block, a moving
  # Saturday/Sunday shuttle that shares that block and therefore keeps it, and a Sunday shuttle
  # plus a specific-dates Monday shuttle that share a second block without ever sharing a date,
  # so the reviewed projection clears both. The type-4 record between the first two trips is a
  # real in-seat transfer the review has to report.
  defp combination_scenario(organization, version) do
    agency_fixture(organization.id, version.id, %{agency_timezone: "Etc/UTC"})
    route = route_fixture(organization.id, version.id, %{route_id: "COMBINE_ROUTE"})

    {:ok, first_stop} =
      GtfsPlanner.Gtfs.create_stop(%{
        stop_id: "CB_S1",
        stop_name: "Combine Stop 1",
        location_type: 0,
        organization_id: organization.id,
        gtfs_version_id: version.id
      })

    {:ok, second_stop} =
      GtfsPlanner.Gtfs.create_stop(%{
        stop_id: "CB_S2",
        stop_name: "Combine Stop 2",
        location_type: 0,
        organization_id: organization.id,
        gtfs_version_id: version.id
      })

    today = postgres_local_today("Etc/UTC")
    next_monday = Date.add(today, rem(8 - Date.day_of_week(today), 7) + 7)

    weekly = [
      {"COMBINE_DEST", 0, 0, 0, 0, 0, 1, 0, Date.add(today, -30), Date.add(today, 60)},
      {"COMBINE_FALL", 0, 0, 0, 0, 0, 1, 1, Date.add(today, -30), Date.add(today, 30)},
      {"COMBINE_SUN", 0, 0, 0, 0, 0, 0, 1, Date.add(today, -10), Date.add(today, 40)}
    ]

    for {service_id, mon, tue, wed, thu, fri, sat, sun, start_date, end_date} <- weekly do
      calendar_fixture(organization.id, version.id, %{
        service_id: service_id,
        monday: mon,
        tuesday: tue,
        wednesday: wed,
        thursday: thu,
        friday: fri,
        saturday: sat,
        sunday: sun,
        start_date: start_date,
        end_date: end_date
      })

      calendar_attribute_fixture(organization.id, version.id, %{
        service_id: service_id,
        service_description: description(service_id)
      })
    end

    calendar_attribute_fixture(organization.id, version.id, %{
      service_id: "COMBINE_MON",
      service_description: description("COMBINE_MON")
    })

    calendar_date_fixture(organization.id, version.id, %{
      service_id: "COMBINE_MON",
      date: next_monday,
      exception_type: 1
    })

    trips = [
      {"COMBINE_DEST", "COMBINE_DEST_1", "KEEP",
       [{~T[08:00:00], first_stop}, {~T[09:00:00], second_stop}]},
      {"COMBINE_DEST", "COMBINE_DEST_2", nil,
       [{~T[10:00:00], first_stop}, {~T[11:00:00], second_stop}]},
      {"COMBINE_FALL", "COMBINE_FALL_1", "KEEP",
       [{~T[09:10:00], second_stop}, {~T[10:00:00], first_stop}]},
      {"COMBINE_SUN", "COMBINE_SUN_1", "CLEAR",
       [{~T[11:00:00], first_stop}, {~T[12:00:00], second_stop}]},
      {"COMBINE_MON", "COMBINE_MON_1", "CLEAR",
       [{~T[18:00:00], first_stop}, {~T[19:00:00], second_stop}]}
    ]

    add_trips(organization, version, route, trips)

    transfer_fixture(organization.id, version.id, %{
      from_trip_id: "COMBINE_DEST_1",
      to_trip_id: "COMBINE_FALL_1",
      from_stop_id: second_stop.stop_id,
      to_stop_id: second_stop.stop_id,
      transfer_type: 4
    })

    %{today: today, route: route, first_stop: first_stop, second_stop: second_stop}
  end

  defp description("COMBINE_DEST"), do: "Saturday service"
  defp description("COMBINE_FALL"), do: "Fall shuttle"
  defp description("COMBINE_SUN"), do: "Sunday shuttle"
  defp description("COMBINE_MON"), do: "Monday shuttle"
  defp description(other), do: other

  # The domain's only conflict shape: two weekly calendars with the same mask where one
  # deliberately removes a regular weekday the other runs. Both sides carry trips, so each option
  # names the trips it affects, and the removal is the exact date the choice decides.
  defp conflict_scenario(organization, version) do
    %{route: route, first_stop: first_stop, second_stop: second_stop, today: today} =
      combination_scenario(organization, version)

    for {service_id, description} <- [
          {"CONFLICT_OFF", "Holiday weekdays"},
          {"CONFLICT_RUN", "Weekday service"}
        ] do
      calendar_fixture(organization.id, version.id, %{
        service_id: service_id,
        monday: 1,
        tuesday: 1,
        wednesday: 1,
        thursday: 1,
        friday: 1,
        start_date: Date.add(today, -20),
        end_date: Date.add(today, 20)
      })

      calendar_attribute_fixture(organization.id, version.id, %{
        service_id: service_id,
        service_description: description
      })
    end

    removal =
      Enum.find(Date.range(Date.add(today, 7), Date.add(today, 21)), &(Date.day_of_week(&1) == 3))

    calendar_date_fixture(organization.id, version.id, %{
      service_id: "CONFLICT_OFF",
      date: removal,
      exception_type: 2
    })

    add_trips(organization, version, route, [
      {"CONFLICT_OFF", "CONFLICT_OFF_1", nil,
       [{~T[06:00:00], first_stop}, {~T[07:00:00], second_stop}]},
      {"CONFLICT_OFF", "CONFLICT_OFF_2", nil,
       [{~T[07:30:00], first_stop}, {~T[08:30:00], second_stop}]},
      {"CONFLICT_RUN", "CONFLICT_RUN_1", nil,
       [{~T[09:00:00], first_stop}, {~T[10:00:00], second_stop}]},
      {"CONFLICT_RUN", "CONFLICT_RUN_2", nil,
       [{~T[10:30:00], first_stop}, {~T[11:30:00], second_stop}]}
    ])

    %{removal: removal, today: today}
  end

  # A moving calendar whose trips would gain far more than the domain's seasonal threshold of
  # upcoming dates: the review has to say so instead of quietly running a seasonal shuttle all year.
  defp seasonal_scenario(organization, version) do
    %{route: route, first_stop: first_stop, second_stop: second_stop, today: today} =
      combination_scenario(organization, version)

    for {service_id, days, description, start_offset, end_offset} <- [
          {"SEASON_DEST", %{monday: 1, tuesday: 1, wednesday: 1, thursday: 1, friday: 1},
           "Weekday service", -30, 60},
          {"SEASON_SAT", %{saturday: 1}, "Saturday shuttle", -10, 10}
        ] do
      calendar_fixture(
        organization.id,
        version.id,
        Map.merge(days, %{
          service_id: service_id,
          start_date: Date.add(today, start_offset),
          end_date: Date.add(today, end_offset)
        })
      )

      calendar_attribute_fixture(organization.id, version.id, %{
        service_id: service_id,
        service_description: description
      })
    end

    add_trips(organization, version, route, [
      {"SEASON_DEST", "SEASON_DEST_1", nil,
       [{~T[06:00:00], first_stop}, {~T[07:00:00], second_stop}]},
      {"SEASON_DEST", "SEASON_DEST_2", nil,
       [{~T[07:30:00], first_stop}, {~T[08:30:00], second_stop}]},
      {"SEASON_SAT", "SEASON_SAT_1", nil,
       [{~T[09:00:00], first_stop}, {~T[10:00:00], second_stop}]}
    ])
  end

  defp add_trips(organization, version, route, trips) do
    for {service_id, trip_id, block_id, times} <- trips do
      trip =
        trip_fixture(organization.id, version.id, route.route_id, %{
          service_id: service_id,
          trip_id: trip_id,
          block_id: block_id
        })

      times
      |> Enum.with_index(1)
      |> Enum.each(fn {{time, stop}, index} ->
        stop_time_fixture(organization.id, version.id, trip.trip_id, stop.stop_id, %{
          arrival_time: "#{time}",
          departure_time: "#{time}",
          stop_sequence: index
        })
      end)
    end
  end

  defp row_counts(version) do
    %{
      calendars:
        Repo.aggregate(from(c in Calendar, where: c.gtfs_version_id == ^version.id), :count),
      dates:
        Repo.aggregate(from(d in CalendarDate, where: d.gtfs_version_id == ^version.id), :count),
      attributes:
        Repo.aggregate(
          from(a in CalendarAttribute, where: a.gtfs_version_id == ^version.id),
          :count
        ),
      trips: Repo.aggregate(from(t in Trip, where: t.gtfs_version_id == ^version.id), :count),
      transfers:
        Repo.aggregate(from(tr in Transfer, where: tr.gtfs_version_id == ^version.id), :count),
      logs: Repo.aggregate(from(l in ChangeLog, where: l.gtfs_version_id == ^version.id), :count)
    }
  end

  describe "selection and the initial review through the real route" do
    test "opens the reviewed combination from the list without writing anything", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      combination_scenario(organization, version)
      conn = editor(conn, user, organization)

      {:ok, view, _html} = live(conn, list_path(version))
      assert loaded(view) =~ "Saturday service"

      # Nothing is selected yet, so the selection bar offers only the select-all control.
      refute has_element?(view, "#calendar-selection-count")
      refute has_element?(view, "#calendar-combine-open")

      before = row_counts(version)

      render_click(view, "toggle_calendar_selection", %{"service-id" => "COMBINE_DEST"})
      assert render(view) =~ "1 calendar selected"
      assert has_element?(view, "#calendar-select-COMBINE_DEST[checked]")
      assert has_element?(view, "#calendar-combine-hint")

      render_click(view, "toggle_calendar_selection", %{"service-id" => "COMBINE_FALL"})
      render_click(view, "toggle_calendar_selection", %{"service-id" => "COMBINE_MON"})
      assert render(view) =~ "3 calendars selected"
      assert has_element?(view, "#calendar-select-COMBINE_MON[checked]")
      refute has_element?(view, "#calendar-combine-open[disabled]")

      html = render_click(view, "open_combine", %{})

      # The drawer carries the reviewed command: the most-used selected calendar is the
      # destination, every source is listed with its real trip count, and the retained sources,
      # the cleared block and the in-seat record come from the loaded rows and the producer.
      assert has_element?(view, "#calendar-combine-drawer-overlay[data-open='true']")
      assert has_element?(view, "#calendar-combine-form")

      assert has_element?(
               view,
               "#calendar-combine-destination-option-COMBINE_DEST input[checked]"
             )

      assert html =~ "3 calendars selected"
      assert html =~ "Keeps 2 + 2 trips"
      assert html =~ "Fall shuttle"
      assert html =~ "leave block CLEAR"
      assert String.downcase(html) =~ "in-seat transfer"
      assert html =~ "stays in the list with 0 trips"
      assert has_element?(view, "#calendar-combine-result-moved")
      assert html =~ "Nothing changes until you combine."
      assert has_element?(view, "#calendar-combine-close")
      refute has_element?(view, "#calendar-combine-decisions")

      assert row_counts(version) == before
    end

    test "changing the destination re-reviews against the real command and writes nothing", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      combination_scenario(organization, version)
      conn = editor(conn, user, organization)

      {:ok, view, _html} = live(conn, list_path(version))
      loaded(view)

      render_click(view, "toggle_calendar_selection", %{"service-id" => "COMBINE_DEST"})
      render_click(view, "toggle_calendar_selection", %{"service-id" => "COMBINE_MON"})
      render_click(view, "open_combine", %{})

      assert has_element?(
               view,
               "#calendar-combine-destination-option-COMBINE_DEST input[checked]"
             )

      before = row_counts(version)

      html =
        render_change(view, "combine_destination", %{
          "combine" => %{"destination_id" => "COMBINE_MON"}
        })

      assert has_element?(view, "#calendar-combine-destination-option-COMBINE_MON input[checked]")

      refute has_element?(
               view,
               "#calendar-combine-destination-option-COMBINE_DEST input[checked]"
             )

      # The Saturday destination runs on far more dates than the Monday shuttle, so the reviewed
      # result changes with the kept calendar instead of reusing the previous projection.
      assert html =~ "Keeps"
      assert row_counts(version) == before
    end

    test "sort and the timeline range keep the selection while a filter prunes it", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      combination_scenario(organization, version)
      conn = editor(conn, user, organization)

      {:ok, view, _html} = live(conn, list_path(version))
      loaded(view)

      render_click(view, "toggle_calendar_selection", %{"service-id" => "COMBINE_DEST"})
      render_click(view, "toggle_calendar_selection", %{"service-id" => "COMBINE_FALL"})
      assert render(view) =~ "2 calendars selected"

      render_click(view, "sort", %{"key" => "name"})
      assert render(view) =~ "2 calendars selected"

      render_patch(view, list_path(version, %{"range" => "near"}))
      assert render(view) =~ "2 calendars selected"

      render_patch(view, list_path(version, %{"search" => "Fall"}))
      assert render(view) =~ "1 calendar selected"
      refute has_element?(view, "#calendar-select-COMBINE_DEST[checked]")
      assert has_element?(view, "#calendar-select-COMBINE_FALL[checked]")

      # The pruned identity is not silently restored when the filter is removed.
      render_patch(view, list_path(version))
      assert render(view) =~ "1 calendar selected"
    end

    test "select-all targets every matching valid row", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      combination_scenario(organization, version)

      # An identity whose retained range cannot be read keeps its row but cannot be selected.
      calendar_fixture(organization.id, version.id, %{
        service_id: "COMBINE_BROKEN",
        saturday: 1,
        start_date: Date.add(postgres_local_today("Etc/UTC"), 30),
        end_date: Date.add(postgres_local_today("Etc/UTC"), -30)
      })

      calendar_attribute_fixture(organization.id, version.id, %{
        service_id: "COMBINE_BROKEN",
        service_description: "Broken shuttle"
      })

      conn = editor(conn, user, organization)

      {:ok, view, _html} = live(conn, list_path(version))
      loaded(view)

      render_click(view, "select_all_calendars", %{})

      assert render(view) =~ "4 calendars selected"
      assert has_element?(view, "#calendar-select-COMBINE_BROKEN[disabled]")
      refute has_element?(view, "#calendar-select-COMBINE_BROKEN[checked]")

      # A forged event for the unreadable identity cannot enter the selection.
      render_click(view, "clear_calendar_selection", %{})
      render_click(view, "toggle_calendar_selection", %{"service-id" => "COMBINE_BROKEN"})
      refute has_element?(view, "#calendar-selection-count")

      # The whole version cannot combine while an identity is unreadable.
      render_click(view, "toggle_calendar_selection", %{"service-id" => "COMBINE_DEST"})
      render_click(view, "toggle_calendar_selection", %{"service-id" => "COMBINE_FALL"})
      assert has_element?(view, "#calendar-combine-unavailable")
      assert has_element?(view, "#calendar-combine-open[disabled]")

      render_click(view, "open_combine", %{})
      refute has_element?(view, "#calendar-combine-form")
    end
  end

  describe "conflict decisions" do
    test "refuses an unanswered conflict, names the missing choice and mutates nothing", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      %{removal: removal} = conflict_scenario(organization, version)
      conn = editor(conn, user, organization)
      expected = Calendar.strftime(removal, "%b %-d, %Y")

      {:ok, view, _html} = live(conn, list_path(version))
      loaded(view)

      render_click(view, "toggle_calendar_selection", %{"service-id" => "CONFLICT_OFF"})
      render_click(view, "toggle_calendar_selection", %{"service-id" => "CONFLICT_RUN"})
      render_click(view, "open_combine", %{})

      group = URI.encode_www_form(Date.to_iso8601(removal))
      fieldset = "#calendar-combine-decisions-#{group}"

      # The exact conflict date is the group, and both decisions are offered with no default, so
      # the reviewer has to make the choice the domain requires.
      assert has_element?(view, fieldset)
      assert has_element?(view, "[data-conflict-date='#{Date.to_iso8601(removal)}']")
      assert has_element?(view, "#{fieldset}-no_service")
      assert has_element?(view, "#{fieldset}-run")
      refute has_element?(view, "#{fieldset}-no_service[checked]")
      refute has_element?(view, "#{fieldset}-run[checked]")

      decisions = render(element(view, "#calendar-combine-decisions"))
      assert decisions =~ expected
      assert decisions =~ "No service"
      assert decisions =~ "Run all trips"
      assert decisions =~ "Holiday weekdays has no service"
      assert decisions =~ "Weekday service runs"
      refute has_element?(view, "#calendar-combine-errors")

      before = row_counts(version)

      html =
        render_submit(view, "combine_apply", %{
          "combine" => %{"destination_id" => "CONFLICT_OFF"}
        })

      # The submission stays available and refuses instead of dispatching an incomplete review: the
      # summary names the missing choice, the group is marked, and its first option is the form's
      # invalid control - which is what the scoped focus hook lands on.
      assert html =~ "Calendars not combined yet."
      assert has_element?(view, "#calendar-combine-errors[role='alert']")
      assert has_element?(view, "#{fieldset}-error")
      assert has_element?(view, "#{fieldset}-no_service[aria-invalid='true']")
      assert html =~ "Choose what happens on #{expected}."

      assert_push_event(view, "focus_form_error", %{
        form_id: "calendar-combine-form",
        fallback_id: "calendar-combine-errors"
      })

      assert row_counts(version) == before
    end

    test "changes the exact consequences with the choice and clears them with the destination", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      %{removal: removal} = conflict_scenario(organization, version)
      conn = editor(conn, user, organization)
      expected = Calendar.strftime(removal, "%b %-d, %Y")
      iso = Date.to_iso8601(removal)
      group = URI.encode_www_form(iso)

      {:ok, view, _html} = live(conn, list_path(version))
      loaded(view)

      render_click(view, "toggle_calendar_selection", %{"service-id" => "CONFLICT_OFF"})
      render_click(view, "toggle_calendar_selection", %{"service-id" => "CONFLICT_RUN"})
      render_click(view, "open_combine", %{})

      assert has_element?(
               view,
               "#calendar-combine-destination-option-CONFLICT_OFF input[checked]"
             )

      before = row_counts(version)

      run_html =
        render_change(view, "combine_change", %{
          "combine" => %{"destination_id" => "CONFLICT_OFF", "decisions" => %{iso => "run"}}
        })

      assert has_element?(view, "#calendar-combine-decisions-#{group}-run[checked]")
      refute has_element?(view, "#calendar-combine-decisions-#{group}-no_service[checked]")
      # Running the date keeps every trip on its own dates, so nothing loses a date.
      assert run_html =~ "Also run on #{expected}"
      refute run_html =~ "Stop running on"

      no_service_html =
        render_change(view, "combine_change", %{
          "combine" => %{
            "destination_id" => "CONFLICT_OFF",
            "decisions" => %{iso => "no_service"}
          }
        })

      assert has_element?(view, "#calendar-combine-decisions-#{group}-no_service[checked]")
      # No service removes exactly that date from the moving trips, which is the other half of the
      # choice the reviewer is making.
      assert no_service_html =~ "Stop running on #{expected}"
      refute no_service_html =~ "Also run on"

      # Keeping another calendar discards the previous answer instead of carrying it into a review
      # whose conflict now belongs to different calendars.
      render_change(view, "combine_change", %{
        "combine" => %{"destination_id" => "CONFLICT_RUN", "decisions" => %{iso => "no_service"}}
      })

      assert has_element?(
               view,
               "#calendar-combine-destination-option-CONFLICT_RUN input[checked]"
             )

      refute has_element?(view, "#calendar-combine-decisions-#{group}-no_service[checked]")
      refute has_element?(view, "#calendar-combine-decisions-#{group}-run[checked]")

      assert row_counts(version) == before
    end

    test "warns when a moving calendar would gain more than fourteen upcoming dates", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      seasonal_scenario(organization, version)
      conn = editor(conn, user, organization)

      {:ok, view, _html} = live(conn, list_path(version))
      loaded(view)

      render_click(view, "toggle_calendar_selection", %{"service-id" => "SEASON_DEST"})
      render_click(view, "toggle_calendar_selection", %{"service-id" => "SEASON_SAT"})
      render_click(view, "open_combine", %{})

      assert has_element?(view, "#calendar-combine-destination-option-SEASON_DEST input[checked]")
      refute has_element?(view, "#calendar-combine-decisions")

      moving = render(element(view, "#calendar-combine-effects-SEASON_SAT"))
      assert moving =~ "Also run on"
      assert moving =~ "If these trips should keep their own dates, don't combine."

      # The warning is about the dates a calendar's trips would gain, so the calendar that stays
      # does not carry it.
      staying = render(element(view, "#calendar-combine-effects-SEASON_DEST"))
      refute staying =~ "don't combine"
    end
  end

  describe "no-op review" do
    test "offers Close and breaks a most-trips tie on the display name and exact ID", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      today = postgres_local_today("Etc/UTC")

      # Two identities with the same trip count and the same case-insensitive display name: the
      # exact service ID decides, and the empty copy keeps its own identity.
      for service_id <- ["TIE_ALPHA", "TIE_BETA"] do
        calendar_fixture(organization.id, version.id, %{
          service_id: service_id,
          monday: 1,
          start_date: Date.add(today, -20),
          end_date: Date.add(today, 20)
        })

        calendar_attribute_fixture(organization.id, version.id, %{
          service_id: service_id,
          service_description: "  tie service  "
        })
      end

      route = route_fixture(organization.id, version.id, %{route_id: "TIE_ROUTE"})

      for service_id <- ["TIE_ALPHA", "TIE_BETA"] do
        trip_fixture(organization.id, version.id, route.route_id, %{
          service_id: service_id,
          trip_id: "#{service_id}_TRIP"
        })
      end

      # An empty identical copy is the no-op source: nothing moves and the dates do not change.
      calendar_fixture(organization.id, version.id, %{
        service_id: "TIE_COPY",
        monday: 1,
        start_date: Date.add(today, -20),
        end_date: Date.add(today, 20)
      })

      calendar_attribute_fixture(organization.id, version.id, %{
        service_id: "TIE_COPY",
        service_description: "  tie service  "
      })

      conn = editor(conn, user, organization)

      {:ok, view, _html} = live(conn, list_path(version))
      loaded(view)

      render_click(view, "toggle_calendar_selection", %{"service-id" => "TIE_ALPHA"})
      render_click(view, "toggle_calendar_selection", %{"service-id" => "TIE_BETA"})
      render_click(view, "open_combine", %{})

      assert has_element?(view, "#calendar-combine-destination-option-TIE_ALPHA input[checked]")
      refute has_element?(view, "#calendar-combine-destination-option-TIE_BETA input[checked]")

      render_click(view, "close_combine", %{})
      assert render(view) =~ "2 calendars selected"

      render_click(view, "clear_calendar_selection", %{})
      render_click(view, "toggle_calendar_selection", %{"service-id" => "TIE_ALPHA"})
      render_click(view, "toggle_calendar_selection", %{"service-id" => "TIE_COPY"})
      html = render_click(view, "open_combine", %{})

      assert html =~ "Nothing changes."
      assert html =~ "Nothing to combine."
      assert has_element?(view, "#calendar-combine-close")

      # Closing keeps the selection: the reviewer can reconsider the same calendars.
      render_click(view, "close_combine", %{})
      refute has_element?(view, "#calendar-combine-form")
      assert render(view) =~ "2 calendars selected"
    end
  end
end
