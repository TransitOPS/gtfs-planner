defmodule GtfsPlannerWeb.Gtfs.CalendarsLiveTest do
  use GtfsPlannerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Mox
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures
  import GtfsPlanner.GtfsFixtures

  import Ecto.Query

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Gtfs.CalendarAttribute
  alias GtfsPlanner.Gtfs.CalendarDate
  alias GtfsPlanner.Gtfs.Calendars
  alias GtfsPlanner.Gtfs.CatalogReadAdapterMock
  alias GtfsPlanner.Repo

  @adapter_key :gtfs_catalog_read_adapter
  @fixed_today ~D[2026-11-16]

  setup :verify_on_exit!

  defp use_real_adapter(context) do
    swap_adapter(nil)
    editor_context(context)
  end

  defp use_mock_adapter(context) do
    swap_adapter(CatalogReadAdapterMock)
    editor_context(context)
  end

  defp swap_adapter(adapter) do
    previous = Application.fetch_env(:gtfs_planner, @adapter_key)

    case adapter do
      nil -> Application.delete_env(:gtfs_planner, @adapter_key)
      module -> Application.put_env(:gtfs_planner, @adapter_key, module)
    end

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:gtfs_planner, @adapter_key, value)
        :error -> Application.delete_env(:gtfs_planner, @adapter_key)
      end
    end)
  end

  defp editor_context(_context) do
    organization = organization_fixture()
    user = user_fixture()

    Accounts.create_user_org_membership(%{
      user_id: user.id,
      organization_id: organization.id,
      roles: ["pathways_studio_editor"]
    })

    %{user: user, organization: organization, version: gtfs_version_fixture(organization.id)}
  end

  # The first paint of the calendar list defers its read, so the static response
  # carries the loading skeleton and the connected socket loads the rows.
  defp loaded(view, attempts \\ 200) do
    html = render(view)

    if settled?(html) or attempts == 0 do
      html
    else
      Process.sleep(10)
      loaded(view, attempts - 1)
    end
  end

  defp settled?(html) do
    Enum.any?(
      [
        "calendars-list-container",
        "calendars-first-use-empty",
        "calendars-unavailable",
        "calendars-version-unavailable"
      ],
      &String.contains?(html, &1)
    )
  end

  defp list_path(version, query \\ %{}) do
    case URI.encode_query(query) do
      "" -> "/gtfs/#{version.id}/calendars"
      encoded -> "/gtfs/#{version.id}/calendars?#{encoded}"
    end
  end

  defp row_ids(html) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("tbody#calendars-list tr td:first-child code")
    |> Enum.map(&LazyHTML.text/1)
  end

  # The axis is a header row and the bars live in the body, so a text extraction over
  # the whole page cannot tell them apart; these read one element's text instead.
  defp text_of(html, selector) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(selector)
    |> Enum.map(&LazyHTML.text/1)
  end

  defp squish(text), do: text |> String.replace(~r/\s+/, " ") |> String.trim()

  # The break and the single day off have to land on regular service days whatever
  # weekday the suite runs, so every fixture date is derived from next week's Monday.
  defp next_monday(today), do: Date.add(today, rem(8 - Date.day_of_week(today), 7) + 7)

  # A fixed offset from today can land on a weekend, so a weekly fixture's first
  # regular service day is the first Mon–Fri date on or after it.
  defp first_service_day(date) do
    if Date.day_of_week(date) <= 5, do: date, else: Date.add(date, 8 - Date.day_of_week(date))
  end

  # The inverse of `first_service_day/1`: the Mon–Fri date a weekly calendar with
  # the given end_date actually serves last.
  defp last_service_day(date) do
    if Date.day_of_week(date) <= 5, do: date, else: Date.add(date, 5 - Date.day_of_week(date))
  end

  defp ends_soon_label(last_date, today) do
    case Date.diff(last_date, today) do
      0 -> "Ends today"
      1 -> "Ends in 1 day"
      days -> "Ends in #{days} days"
    end
  end

  defp postgres_local_today(timezone) do
    %{rows: [[%Date{} = date]]} = Repo.query!("SELECT (now() AT TIME ZONE $1)::date", [timezone])

    date
  end

  # Builds a real summary through the domain read so the adapter seam is stubbed
  # with the production shape instead of a hand-written map.
  defp real_summary(organization, version, service_id, name, attrs \\ %{}) do
    calendar_attribute_fixture(
      organization.id,
      version.id,
      Map.merge(%{service_id: service_id, service_description: name}, attrs)
    )

    {:ok, summaries} = Calendars.list_calendars(organization.id, version.id, today: @fixed_today)
    Enum.find(summaries, &(&1.service_id == service_id))
  end

  # The route reads one screen snapshot, so the adapter seam supplies that shape. A
  # plain row list is wrapped in a screen built from those rows, which keeps the
  # existing cases readable while the seam matches the production read.
  defp stub_screen(result_fn) do
    stub(CatalogReadAdapterMock, :load_calendar_screen, fn _org, _version, opts ->
      case result_fn.(opts) do
        {:ok, %{rows: _rows} = screen} -> {:ok, screen}
        {:ok, rows} -> {:ok, screen(rows)}
        error -> error
      end
    end)
  end

  defp screen(rows, overrides \\ %{}) do
    Map.merge(
      %{
        rows: rows,
        invalid_calendars: [],
        today: @fixed_today,
        zone: %{date: @fixed_today, fallback?: false, fallback_reason: nil},
        horizon: horizon(rows),
        gaps: [],
        complete?: true
      },
      overrides
    )
  end

  defp horizon(rows) do
    first = rows |> Enum.map(& &1.first_active_date) |> Enum.reject(&is_nil/1)

    if first == [] do
      nil
    else
      last = rows |> Enum.map(& &1.last_active_date) |> Enum.reject(&is_nil/1)
      %{first_date: Enum.min(first, Date), last_date: Enum.max(last, Date)}
    end
  end

  describe "authenticated scoped list through the real Repo adapter" do
    setup :use_real_adapter

    test "shows union identities, grouped usage, agency-local today and feed gaps", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      conn = log_in_user(conn, user, organization: organization)

      today = postgres_local_today("Pacific/Kiritimati")
      agency_fixture(organization.id, version.id, %{agency_timezone: "Pacific/Kiritimati"})

      route = route_fixture(organization.id, version.id, %{route_id: "R1"})

      calendar_fixture(organization.id, version.id, %{
        service_id: "WKD",
        monday: 1,
        tuesday: 1,
        wednesday: 1,
        thursday: 1,
        friday: 1,
        saturday: 1,
        sunday: 1,
        start_date: Date.add(today, -30),
        end_date: today
      })

      calendar_attribute_fixture(organization.id, version.id, %{
        service_id: "WKD",
        service_description: "Weekday service"
      })

      trip_fixture(organization.id, version.id, route.route_id, %{service_id: "WKD"})
      trip_fixture(organization.id, version.id, route.route_id, %{service_id: "WKD"})

      calendar_date_fixture(organization.id, version.id, %{
        service_id: "EVENT",
        date: Date.add(today, 200),
        exception_type: 1
      })

      calendar_attribute_fixture(organization.id, version.id, %{
        service_id: "META",
        service_description: "Metadata only"
      })

      {:ok, view, static_html} = live(conn, list_path(version))

      assert static_html =~ "calendars-loading"
      assert static_html =~ "Loading calendars…"

      html = loaded(view)
      doc = LazyHTML.from_fragment(html)

      assert row_ids(html) == ["EVENT", "META", "WKD"]
      assert Enum.count(LazyHTML.query(doc, "tbody#calendars-list tr")) == 3

      assert html =~ "Weekday service"
      assert html =~ "Metadata only"

      # Grouped usage and the agency-local date both come from the real read.
      assert html =~ "Today · #{Calendar.strftime(today, "%b %-d, %Y")}"

      assert html
             |> text_of(~s(#calendars-list td[data-label="Trips"]))
             |> Enum.map(&String.trim/1) ==
               ["0", "0", "2"]

      assert html =~ "Ends today"
      assert html =~ "run today"
      assert html =~ "ending soon"
      assert html =~ "No service"
      assert html =~ "Not used by trips"

      # The weekly calendar's Monday-to-today range leaves no gap, but the far
      # addition and the metadata-only identity define a version-wide span with one.
      assert html =~ "calendars-feed-gap"
      assert html =~ "No service on any calendar:"
    end

    test "a foreign version discloses no data", %{
      conn: conn,
      user: user,
      organization: organization
    } do
      conn = log_in_user(conn, user, organization: organization)

      other_organization = organization_fixture()
      other_version = gtfs_version_fixture(other_organization.id)

      calendar_attribute_fixture(other_organization.id, other_version.id, %{
        service_id: "FOREIGN_SECRET",
        service_description: "Foreign secret"
      })

      assert {:error, {:redirect, %{to: "/"}}} = live(conn, list_path(other_version))
    end
  end

  describe "agency timezone disclosure" do
    setup :use_real_adapter

    for {reason, zones, sentence} <- [
          {:missing, [], "time zone is missing"},
          {:invalid, ["Not/AZone"], "isn’t a valid time zone"},
          {:conflicting, ["Etc/UTC", "America/New_York"], "different time zones"}
        ] do
      @reason reason
      @zones zones
      @sentence sentence
      test "discloses #{@reason} timezone on ordinary list entry", context do
        calendar_attribute_fixture(context.organization.id, context.version.id, %{
          service_id: "ZONE",
          service_description: "Timezone calendar"
        })

        for zone <- @zones,
            do:
              agency_fixture(context.organization.id, context.version.id, %{agency_timezone: zone})

        {:ok, view, _} =
          live(
            log_in_user(context.conn, context.user, organization: context.organization),
            list_path(context.version)
          )

        loaded(view)
        assert has_element?(view, "#calendars-timezone-fallback", @sentence)
        assert has_element?(view, "#calendars-timezone-fallback", "use UTC")
      end
    end
  end

  describe "URL state through the real Repo adapter" do
    setup :use_real_adapter

    test "search, sort and status filters round-trip and nil period dates stay last", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      conn = log_in_user(conn, user, organization: organization)
      today = postgres_local_today("Etc/UTC")

      # Alpha: Monday-to-Friday weekly service whose derived period always spans today.
      calendar_fixture(organization.id, version.id, %{
        service_id: "WEEKD",
        start_date: Date.add(today, -60),
        end_date: Date.add(today, 60)
      })

      calendar_attribute_fixture(organization.id, version.id, %{
        service_id: "WEEKD",
        service_description: "Alpha weekdays"
      })

      # Today's own service is removed, so this calendar contributes its period
      # without also claiming to run today whatever weekday "today" happens to be.
      calendar_date_fixture(organization.id, version.id, %{
        service_id: "WEEKD",
        date: today,
        exception_type: 2
      })

      # Beta: every-day weekly service with today's own service removed, so its
      # period covers today while today is not one of its active dates.
      calendar_fixture(organization.id, version.id, %{
        service_id: "OFFDAY",
        monday: 1,
        tuesday: 1,
        wednesday: 1,
        thursday: 1,
        friday: 1,
        saturday: 1,
        sunday: 1,
        start_date: Date.add(today, -30),
        end_date: Date.add(today, 30)
      })

      calendar_attribute_fixture(organization.id, version.id, %{
        service_id: "OFFDAY",
        service_description: "Beta off today"
      })

      calendar_date_fixture(organization.id, version.id, %{
        service_id: "OFFDAY",
        date: today,
        exception_type: 2
      })

      # Gamma: every-day weekly service, active today.
      calendar_fixture(organization.id, version.id, %{
        service_id: "ALLDAYS",
        monday: 1,
        tuesday: 1,
        wednesday: 1,
        thursday: 1,
        friday: 1,
        saturday: 1,
        sunday: 1,
        start_date: Date.add(today, -30),
        end_date: Date.add(today, 30)
      })

      calendar_attribute_fixture(organization.id, version.id, %{
        service_id: "ALLDAYS",
        service_description: "Gamma every day"
      })

      # Middle: an attributes-only identity with no active date at all.
      calendar_attribute_fixture(organization.id, version.id, %{
        service_id: "NODATES",
        service_description: "Middle no dates"
      })

      # Zeta: a dates-only identity active only in three days.
      calendar_date_fixture(organization.id, version.id, %{
        service_id: "TODAYONLY",
        date: Date.add(today, 3),
        exception_type: 1
      })

      calendar_attribute_fixture(organization.id, version.id, %{
        service_id: "TODAYONLY",
        service_description: "Zeta future date"
      })

      {:ok, view, static_html} = live(conn, list_path(version))
      assert static_html =~ "calendars-loading"

      # Default name ascending with the service-ID tie-break.
      assert row_ids(loaded(view)) == ["WEEKD", "OFFDAY", "ALLDAYS", "NODATES", "TODAYONLY"]

      assert row_ids(
               render_patch(
                 view,
                 list_path(version, %{"sort_by" => "name", "sort_dir" => "desc"})
               )
             ) == ["TODAYONLY", "NODATES", "ALLDAYS", "OFFDAY", "WEEKD"]

      # Period sort uses the first effective active date and keeps identities
      # without one last in both directions.
      assert row_ids(
               render_patch(
                 view,
                 list_path(version, %{"sort_by" => "period", "sort_dir" => "asc"})
               )
             ) == ["WEEKD", "OFFDAY", "ALLDAYS", "TODAYONLY", "NODATES"]

      assert row_ids(
               render_patch(
                 view,
                 list_path(version, %{"sort_by" => "period", "sort_dir" => "desc"})
               )
             ) == ["TODAYONLY", "ALLDAYS", "OFFDAY", "WEEKD", "NODATES"]

      # The rendered sort controls carry their keyboard state.
      desc = render_patch(view, list_path(version, %{"sort_by" => "name", "sort_dir" => "desc"}))
      assert desc =~ ~s{aria-sort="descending"}

      asc = render_patch(view, list_path(version, %{"sort_by" => "name", "sort_dir" => "asc"}))
      assert asc =~ ~s{aria-sort="ascending"}

      # Search matches names and service IDs.
      assert row_ids(render_patch(view, list_path(version, %{"search" => "alpha"}))) == ["WEEKD"]

      assert row_ids(render_patch(view, list_path(version, %{"search" => "TODAYONLY"}))) ==
               ["TODAYONLY"]

      # Active period includes the calendar whose period covers today even though
      # today's own service is removed, and the dates-only addition is excluded.
      assert row_ids(render_patch(view, list_path(version, %{"status" => "active_period"}))) ==
               ["WEEKD", "OFFDAY", "ALLDAYS"]

      assert row_ids(render_patch(view, list_path(version, %{"status" => "active_today"}))) ==
               ["ALLDAYS"]

      assert row_ids(render_patch(view, list_path(version, %{"status" => "unused"}))) ==
               ["WEEKD", "OFFDAY", "ALLDAYS", "NODATES", "TODAYONLY"]

      ended = render_patch(view, list_path(version, %{"status" => "ended"}))
      assert ended =~ "calendars-filtered-empty"
      assert ended =~ "0 of 5 calendars"

      assert row_ids(render_patch(view, list_path(version, %{"status" => "ends_soon"}))) ==
               ["TODAYONLY"]

      # Unknown filter values are not allowlisted.
      assert row_ids(render_patch(view, list_path(version, %{"status" => "not-a-status"}))) ==
               ["WEEKD", "OFFDAY", "ALLDAYS", "NODATES", "TODAYONLY"]

      # The patched address survives a reload and back navigation.
      url = list_path(version, %{"search" => "alpha", "status" => "active_today"})

      assert {:ok, reloaded, _html} = live(conn, url)
      assert loaded(reloaded) =~ "No calendars match these filters"
    end

    test "the agency-local today is never taken from the URL", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      conn = log_in_user(conn, user, organization: organization)
      today = postgres_local_today("Etc/UTC")

      calendar_date_fixture(organization.id, version.id, %{
        service_id: "TODAY",
        date: today,
        exception_type: 1
      })

      calendar_attribute_fixture(organization.id, version.id, %{
        service_id: "TODAY",
        service_description: "Today only"
      })

      calendar_fixture(organization.id, version.id, %{
        service_id: "ALLDAYS",
        monday: 1,
        tuesday: 1,
        wednesday: 1,
        thursday: 1,
        friday: 1,
        saturday: 1,
        sunday: 1,
        start_date: Date.add(today, -60),
        end_date: Date.add(today, 60)
      })

      calendar_attribute_fixture(organization.id, version.id, %{
        service_id: "ALLDAYS",
        service_description: "Every day"
      })

      route = route_fixture(organization.id, version.id, %{route_id: "R9"})
      trip_fixture(organization.id, version.id, route.route_id, %{service_id: "ALLDAYS"})

      {:ok, view, _html} = live(conn, list_path(version, %{"today" => "2000-01-01"}))
      html = loaded(view)

      assert html =~ "Today · #{Calendar.strftime(today, "%b %-d, %Y")}"
      assert html =~ "Runs today"
      assert html =~ "Ends today"
    end

    test "generated detail links keep URI-encoded service IDs", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      conn = log_in_user(conn, user, organization: organization)

      weird_id = "svc/with space%and+plus"

      calendar_attribute_fixture(organization.id, version.id, %{
        service_id: weird_id,
        service_description: "Encoded service"
      })

      {:ok, view, _html} = live(conn, list_path(version))
      html = loaded(view)

      assert html =~ "Encoded service"

      assert html =~
               "/gtfs/#{version.id}/calendars/show?service_id=" <> URI.encode_www_form(weird_id)

      # Creation and detail links are reachable; the cross-calendar drawer and its
      # date-change controls belong to step 7 and are still absent.
      assert html =~ "/gtfs/#{version.id}/calendars/new"
      assert html =~ "Create calendar"
      assert html =~ ~s(id="calendar-date-change")
      refute html =~ "Add break"
      refute html =~ "Duplicate calendar"
      refute html =~ "Delete calendar"
    end
  end

  describe "coverage axis through the real Repo adapter" do
    setup :use_real_adapter

    test "the ordinary route draws the axis, the exact-date captions and the legend", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      conn = log_in_user(conn, user, organization: organization)
      today = postgres_local_today("Etc/UTC")
      monday = next_monday(today)

      # Three consecutive removed regular days are a break; one removed day is a day
      # off; a Saturday addition is an added date. Every date is derived from next
      # week's Monday, so the derived counts hold whatever weekday the suite runs.
      calendar_fixture(organization.id, version.id, %{
        service_id: "COVER_WEEK",
        start_date: Date.add(today, -28),
        end_date: Date.add(today, 28)
      })

      calendar_attribute_fixture(organization.id, version.id, %{
        service_id: "COVER_WEEK",
        service_description: "Covered weekdays"
      })

      for removed <- [monday, Date.add(monday, 1), Date.add(monday, 2)] do
        calendar_date_fixture(organization.id, version.id, %{
          service_id: "COVER_WEEK",
          date: removed,
          exception_type: 2
        })
      end

      calendar_date_fixture(organization.id, version.id, %{
        service_id: "COVER_WEEK",
        date: Date.add(monday, 14),
        exception_type: 2
      })

      calendar_date_fixture(organization.id, version.id, %{
        service_id: "COVER_WEEK",
        date: Date.add(monday, 5),
        exception_type: 1
      })

      # A dates-only identity keeps one exact date and is its own row.
      only_date = Date.add(today, 2)

      calendar_date_fixture(organization.id, version.id, %{
        service_id: "COVER_DATES",
        date: only_date,
        exception_type: 1
      })

      calendar_attribute_fixture(organization.id, version.id, %{
        service_id: "COVER_DATES",
        service_description: "Covered dates"
      })

      {:ok, view, _html} = live(conn, list_path(version))
      html = loaded(view)

      # The range control is a labelled keyboard group whose default is the whole feed.
      assert has_element?(view, "#calendar-coverage-range[role=group]")
      assert has_element?(view, "#calendar-coverage-range-whole[aria-current=true]")
      refute has_element?(view, "#calendar-coverage-range-near[aria-current=true]")

      # One axis serves every row, and every row carries its own bar on it.
      assert has_element?(view, "#calendar-coverage-axis")
      assert has_element?(view, "[data-calendar-coverage='COVER_WEEK']")
      assert has_element?(view, "[data-calendar-coverage='COVER_DATES']")

      # The axis names its months in text and marks today.
      assert html =~ "calendar-coverage-tick-label"
      assert has_element?(view, "#calendar-coverage-axis .calendar-coverage-today")

      # The caption states the exact dates and the derived counts, so the bar is never
      # the only carrier of a fact.
      assert html =~ "Covered weekdays"
      assert html =~ "1 break"
      assert html =~ "1 day off"
      assert html =~ "1 added date"
      assert html =~ "1 date · #{Calendar.strftime(only_date, "%b %-d, %Y")}"

      for word <- [
            "Regular service",
            "Day off",
            "Break",
            "Added date",
            "No service on any calendar",
            "Today"
          ] do
        assert has_element?(view, "#calendar-coverage-legend", word)
      end
    end

    test "the timeline range is allowlisted URL state and the disclosed long history offers a way back",
         %{
           conn: conn,
           user: user,
           organization: organization,
           version: version
         } do
      conn = log_in_user(conn, user, organization: organization)
      today = postgres_local_today("Etc/UTC")

      calendar_fixture(organization.id, version.id, %{
        service_id: "LONG_WEEK",
        start_date: Date.add(today, -3_200),
        end_date: Date.add(today, 400)
      })

      calendar_attribute_fixture(organization.id, version.id, %{
        service_id: "LONG_WEEK",
        service_description: "Nine year weekdays"
      })

      {:ok, view, _html} = live(conn, list_path(version))
      whole = loaded(view)

      # A history longer than 24 months opens on the disclosed recent window, keeps the
      # row's exact dates and offers every year.
      assert has_element?(view, "#calendar-coverage-window")
      assert whole =~ "Timeline starts"
      assert whole =~ "is hidden"
      assert has_element?(view, "#calendar-coverage-show-all")

      assert whole =~
               "#{Calendar.strftime(first_service_day(Date.add(today, -3_200)), "%b %-d, %Y")}"

      # Every year is the same axis without the window, and it can be restored.
      all = render_patch(view, list_path(version, %{"range" => "all"}))
      assert has_element?(view, "#calendar-coverage-restore")
      assert all =~ "Every year of this version is shown"
      refute has_element?(view, "#calendar-coverage-show-all")

      # The near view is the third allowlisted value; anything else is the default.
      near = render_patch(view, list_path(version, %{"range" => "near"}))
      assert has_element?(view, "#calendar-coverage-range-near[aria-current=true]")
      assert near =~ "calendar-coverage-axis"

      assert render_patch(view, list_path(version, %{"range" => "later"})) =~
               "calendar-coverage-range-whole"

      assert has_element?(view, "#calendar-coverage-range-whole[aria-current=true]")
    end

    test "an unreadable imported range names its identity and repair action without asserting no service",
         %{
           conn: conn,
           user: user,
           organization: organization,
           version: version
         } do
      conn = log_in_user(conn, user, organization: organization)
      today = postgres_local_today("Etc/UTC")

      calendar_fixture(organization.id, version.id, %{
        service_id: "READABLE",
        start_date: Date.add(today, -30),
        end_date: Date.add(today, 30)
      })

      calendar_attribute_fixture(organization.id, version.id, %{
        service_id: "READABLE",
        service_description: "Readable weekdays"
      })

      # The import accepts this row and the date evaluator refuses it.
      calendar_fixture(organization.id, version.id, %{
        service_id: "REVERSED",
        start_date: Date.add(today, 60),
        end_date: Date.add(today, -60)
      })

      calendar_attribute_fixture(organization.id, version.id, %{
        service_id: "REVERSED",
        service_description: "Reversed imported range"
      })

      {:ok, view, _html} = live(conn, list_path(version))
      html = loaded(view)

      # The repair state names the identity and the one action that fixes it.
      assert has_element?(view, "#calendar-coverage-invalid")
      assert has_element?(view, "[data-calendar-coverage-repair='REVERSED']")

      assert has_element?(
               view,
               "#calendar-coverage-invalid-repair[href='/gtfs/#{version.id}/import']"
             )

      assert html =~ "REVERSED"
      assert html =~ "Range needs repair"

      # The unreadable row asserts no date fact, and the version claims no complete
      # gap set (the read reports gaps as nil rather than an empty list).
      refute html =~ "No service dates"
      refute has_element?(view, "#calendars-feed-gap")

      # The readable identity keeps its aligned bar beside the repair state.
      assert has_element?(view, "[data-calendar-coverage='READABLE']")
      assert html =~ "Readable weekdays"
    end

    test "filtering rows leaves the shared axis and the version-wide gaps unchanged", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      conn = log_in_user(conn, user, organization: organization)
      today = postgres_local_today("Etc/UTC")

      # Two identities with a real gap between them, so the gap callout exists.
      calendar_fixture(organization.id, version.id, %{
        service_id: "ALPHA",
        start_date: Date.add(today, -40),
        end_date: Date.add(today, -10)
      })

      calendar_attribute_fixture(organization.id, version.id, %{
        service_id: "ALPHA",
        service_description: "Alpha weekdays"
      })

      calendar_fixture(organization.id, version.id, %{
        service_id: "BETA",
        start_date: Date.add(today, 10),
        end_date: Date.add(today, 40)
      })

      calendar_attribute_fixture(organization.id, version.id, %{
        service_id: "BETA",
        service_description: "Beta weekdays"
      })

      {:ok, view, _html} = live(conn, list_path(version))
      full = loaded(view)
      assert full =~ "calendars-feed-gap"

      filtered = render_patch(view, list_path(version, %{"search" => "alpha"}))

      # One row is shown and the result count says so, while the version-wide facts
      # come from the unfiltered read.
      assert filtered =~ "1 of 2 calendars"
      assert text_of(filtered, "#calendars-list tr") |> length() == 1

      assert text_of(full, "#calendar-coverage-axis") ==
               text_of(filtered, "#calendar-coverage-axis")

      assert text_of(full, "#calendars-feed-gap") == text_of(filtered, "#calendars-feed-gap")

      # The range is a view of the same snapshot, not a filter: it survives a filter
      # change and the filter survives a range change.
      narrowed = render_patch(view, list_path(version, %{"search" => "alpha", "range" => "near"}))
      assert narrowed =~ "1 of 2 calendars"
      assert has_element?(view, "#calendar-coverage-range-near[aria-current=true]")
    end
  end

  describe "coverage details inspector through the real Repo adapter" do
    setup :use_real_adapter

    test "opens one identity's exact periods, breaks, days off, additions, next service and usage",
         %{
           conn: conn,
           user: user,
           organization: organization,
           version: version
         } do
      conn = log_in_user(conn, user, organization: organization)
      today = postgres_local_today("Etc/UTC")
      monday = next_monday(today)
      route_a = route_fixture(organization.id, version.id, %{route_id: "CHIP_A"})
      route_b = route_fixture(organization.id, version.id, %{route_id: "CHIP_B"})

      # Three consecutive removed regular service days are a break, one removed day is
      # a day off, and an addition inside the range is regular extra service. Every date
      # is derived from next week's Monday, so the derived counts hold on any run day.
      calendar_fixture(organization.id, version.id, %{
        service_id: "DETAIL_WEEK",
        start_date: Date.add(today, -21),
        end_date: Date.add(today, 28)
      })

      calendar_attribute_fixture(organization.id, version.id, %{
        service_id: "DETAIL_WEEK",
        service_description: "Detailed weekdays"
      })

      for removed <- [monday, Date.add(monday, 1), Date.add(monday, 2)] do
        calendar_date_fixture(organization.id, version.id, %{
          service_id: "DETAIL_WEEK",
          date: removed,
          exception_type: 2
        })
      end

      calendar_date_fixture(organization.id, version.id, %{
        service_id: "DETAIL_WEEK",
        date: Date.add(monday, 7),
        exception_type: 2
      })

      calendar_date_fixture(organization.id, version.id, %{
        service_id: "DETAIL_WEEK",
        date: Date.add(monday, 5),
        exception_type: 1
      })

      # Two additions after the weekly range: exact out-of-range additions.
      outside_first = Date.add(today, 60)
      outside_last = Date.add(today, 61)

      for date <- [outside_first, outside_last] do
        calendar_date_fixture(organization.id, version.id, %{
          service_id: "DETAIL_WEEK",
          date: date,
          exception_type: 1
        })
      end

      trip_fixture(organization.id, version.id, route_a.route_id, %{service_id: "DETAIL_WEEK"})
      trip_fixture(organization.id, version.id, route_b.route_id, %{service_id: "DETAIL_WEEK"})

      {:ok, view, _html} = live(conn, list_path(version))
      list_html = loaded(view)

      # The control is one keyboard button that carries the row's exact service ID, and
      # the caption stays the accessible name so the bar is never the only statement.
      assert has_element?(
               view,
               "button#calendar-coverage-open-DETAIL_WEEK" <>
                 "[data-calendar-coverage='DETAIL_WEEK']" <>
                 "[phx-value-service-id='DETAIL_WEEK'][aria-haspopup='dialog']"
             )

      assert list_html =~ "Detailed weekdays coverage details"

      html = render_click(view, "open_coverage_details", %{"service-id" => "DETAIL_WEEK"})

      # The inspector is the existing drawer, opened for that exact identity and ready
      # to return focus to the control that opened it.
      assert has_element?(view, "#calendar-coverage-details-overlay[data-open=true]")

      # The dialog — the element the overlay hook reads — carries the exact id of the
      # control that opened this inspector, so Escape can return focus to it, and that
      # control is the element with that id.
      assert has_element?(
               view,
               "#calendar-coverage-details-overlay" <>
                 "[data-return-focus-id='calendar-coverage-open-DETAIL_WEEK']"
             )

      assert has_element?(view, "button#calendar-coverage-open-DETAIL_WEEK")

      assert has_element?(view, "#calendar-coverage-details-title", "Detailed weekdays")

      assert text_of(html, "#calendar-coverage-details-identity") |> Enum.join(" ") =~
               "DETAIL_WEEK"

      # Periods, the break with its exact range and its three removed service days, the
      # single day off and the additions all come from the loaded read.
      break_range =
        "#{Calendar.strftime(monday, "%b %-d, %Y")} – " <>
          Calendar.strftime(Date.add(monday, 2), "%b %-d, %Y")

      day_off = Calendar.strftime(Date.add(monday, 7), "%b %-d, %Y")
      inside_addition = Calendar.strftime(Date.add(monday, 5), "%b %-d, %Y")

      assert has_element?(
               view,
               "#calendar-coverage-details-periods",
               "Break · #{break_range} · 3 service days removed"
             )

      assert has_element?(
               view,
               "#calendar-coverage-details-periods",
               "Single days off: #{day_off}"
             )

      assert has_element?(
               view,
               "#calendar-coverage-details-periods",
               "Extra service: #{inside_addition}"
             )

      assert has_element?(
               view,
               "#calendar-coverage-details-periods",
               "outside the regular schedule"
             )

      # Every stored addition and removal is listed exactly, including the additions
      # after the weekly range.
      assert length(text_of(html, "#calendar-coverage-details-dates li")) == 7
      assert has_element?(view, "#calendar-coverage-details-dates", "Service removed")
      assert has_element?(view, "#calendar-coverage-details-dates", "Service added")

      assert has_element?(
               view,
               "#calendar-coverage-details-dates",
               Calendar.strftime(outside_first, "%b %-d, %Y")
             )

      assert has_element?(
               view,
               "#calendar-coverage-details-dates",
               Calendar.strftime(outside_last, "%b %-d, %Y")
             )

      # Next service is the first loaded date on or after the agency-local today,
      # skipping the fixture's own removals: Monday next week, its two following
      # regular days and the single day off the week after. On a weekend run day the
      # removed Monday is the first candidate, so the expectation walks past it.
      removals = [
        monday,
        Date.add(monday, 1),
        Date.add(monday, 2),
        Date.add(monday, 7)
      ]

      expected_next =
        Enum.find(
          Stream.iterate(today, &Date.add(&1, 1)),
          &(Date.day_of_week(&1) <= 5 and &1 not in removals)
        )

      expected_label =
        if expected_next == today do
          "Today, #{Calendar.strftime(today, "%a, %b %-d, %Y")}"
        else
          Calendar.strftime(expected_next, "%a, %b %-d, %Y")
        end

      assert text_of(html, "#calendar-coverage-details-next") == [expected_label]
      assert has_element?(view, "#calendar-coverage-details-usage", "2 trips use this calendar")
      assert has_element?(view, "#calendar-coverage-details-usage-route-CHIP_A")
      assert has_element?(view, "#calendar-coverage-details-usage-route-CHIP_B")

      # Every exact date falls inside this axis, so the inspector says so rather than
      # implying dates were dropped.
      assert text_of(html, "#calendar-coverage-details-outside li") |> Enum.join(" ") =~
               "Every service date falls inside the timeline."

      # Closing drops the inspector content and keeps the control in place for focus.
      closed = render_click(view, "close_coverage_details", %{})
      assert has_element?(view, "#calendar-coverage-details-overlay[data-open=false]")
      refute closed =~ "3 service days removed"
      refute has_element?(view, "#calendar-coverage-details-content")
      assert has_element?(view, "button#calendar-coverage-open-DETAIL_WEEK")
    end

    test "counts the exact dates outside the drawn timeline on a long feed", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      conn = log_in_user(conn, user, organization: organization)
      today = postgres_local_today("Etc/UTC")
      start_date = Date.add(today, -3_200)

      # Nine years of daily service make the whole-feed axis the disclosed recent window
      # from twelve months before today, so this row keeps most of its exact dates
      # outside it.
      calendar_fixture(organization.id, version.id, %{
        service_id: "DETAIL_LONG",
        monday: 1,
        tuesday: 1,
        wednesday: 1,
        thursday: 1,
        friday: 1,
        saturday: 1,
        sunday: 1,
        start_date: start_date,
        end_date: Date.add(today, 400)
      })

      calendar_attribute_fixture(organization.id, version.id, %{
        service_id: "DETAIL_LONG",
        service_description: "Nine year service"
      })

      {:ok, view, _html} = live(conn, list_path(version))
      _list_html = loaded(view)

      html = render_click(view, "open_coverage_details", %{"service-id" => "DETAIL_LONG"})
      outside = text_of(html, "#calendar-coverage-details-outside li") |> Enum.join(" ")
      axis_first = Date.new!(today.year - 1, today.month, 1)

      # The count and the exact span before the drawn range, closed by the statement
      # that the timeline is a view rather than a limit on the dates (INV-5).
      assert outside =~ ~r/\b\d+ service dates before/

      assert outside =~
               "before #{Calendar.strftime(axis_first, "%b %-d, %Y")}: " <>
                 "#{Calendar.strftime(start_date, "%b %-d, %Y")} – " <>
                 Calendar.strftime(Date.add(axis_first, -1), "%b %-d, %Y")

      assert outside =~ "none of them is dropped"
    end

    test "routes an unreadable identity to its detail page but never into the coverage inspector or the date-change targets",
         %{
           conn: conn,
           user: user,
           organization: organization,
           version: version
         } do
      conn = log_in_user(conn, user, organization: organization)
      today = postgres_local_today("Etc/UTC")

      # The readable identity has to serve the date selected at the bottom of this
      # test, and `next_monday/1` can land up to thirteen days out, so its range is
      # anchored to that Monday rather than to today.
      monday = next_monday(today)

      calendar_fixture(organization.id, version.id, %{
        service_id: "DETAIL_OK",
        start_date: Date.add(monday, -10),
        end_date: Date.add(monday, 10)
      })

      calendar_attribute_fixture(organization.id, version.id, %{
        service_id: "DETAIL_OK",
        service_description: "Readable detail weekdays"
      })

      calendar_fixture(organization.id, version.id, %{
        service_id: "DETAIL_REVERSED",
        start_date: Date.add(today, 60),
        end_date: Date.add(today, -60)
      })

      calendar_attribute_fixture(organization.id, version.id, %{
        service_id: "DETAIL_REVERSED",
        service_description: "Reversed detail range"
      })

      {:ok, view, _html} = live(conn, list_path(version))
      html = loaded(view)

      # The identity stays listed with its name and usage and has no coverage control.
      # The detail page opens it so the dates can be corrected, so the repair state
      # links there beside the import action.
      assert html =~ "Reversed detail range"
      refute has_element?(view, "[data-calendar-coverage='DETAIL_REVERSED']")
      assert has_element?(view, "[data-calendar-coverage-repair='DETAIL_REVERSED']")

      assert has_element?(
               view,
               "#calendar-coverage-fix-DETAIL_REVERSED[href='/gtfs/#{version.id}/calendars/show?service_id=DETAIL_REVERSED']",
               "Fix dates"
             )

      assert has_element?(
               view,
               "#calendar-coverage-repair-DETAIL_REVERSED[href='/gtfs/#{version.id}/import']"
             )

      assert html =~ "Correct the calendar file and import the feed again"
      assert has_element?(view, "[data-calendar-link='DETAIL_OK']")

      # Neither the control's own event nor a forged service ID opens the inspector.
      for service_id <- ["DETAIL_REVERSED", "NO_SUCH_CALENDAR"] do
        render_click(view, "open_coverage_details", %{"service-id" => service_id})
        assert has_element?(view, "#calendar-coverage-details-overlay[data-open=false]")
        refute has_element?(view, "#calendar-coverage-details-content")
      end

      # The reviewed date change evaluates every target, so the unreadable identity is
      # neither offered nor accepted as a target while the readable one is.
      render_click(view, "open_date_change", %{})

      view
      |> form("#calendar-date-change-form",
        date_change: %{mode: "single", date: Date.to_iso8601(monday)}
      )
      |> render_change()

      assert has_element?(view, "#calendar-date-change-add-DETAIL_OK")
      assert has_element?(view, "#calendar-date-change-remove-DETAIL_OK")
      refute has_element?(view, "#calendar-date-change-add-DETAIL_REVERSED")
      refute has_element?(view, "#calendar-date-change-remove-DETAIL_REVERSED")

      assert render_click(view, "date_change_toggle", %{
               "group" => "add",
               "service-id" => "DETAIL_REVERSED"
             }) =~ "not in this service version"

      # The repair link opens the detail page with its range error.
      assert {:ok, detail, _html} =
               view
               |> element("#calendar-coverage-fix-DETAIL_REVERSED")
               |> render_click()
               |> follow_redirect(conn)

      assert has_element?(detail, "#calendar-range-error")
    end
  end

  describe "states through the adapter seam" do
    setup :use_mock_adapter

    test "loading, refreshing, filtered empty and unavailable stay distinct", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      conn = log_in_user(conn, user, organization: organization)

      summary = real_summary(organization, version, "WKD", "Weekday service")

      stub_screen(fn _opts -> {:ok, [summary]} end)

      {:ok, view, static_html} = live(conn, list_path(version))

      assert static_html =~ "calendars-loading"
      refute static_html =~ "calendars-list-container"

      assert render(view) =~ "Weekday service"

      refreshing = render_click(view, "refresh")

      assert refreshing =~ "calendars-refreshing"
      assert refreshing =~ "The list stays as it was."
      assert refreshing =~ "Weekday service"
      assert render(view) =~ "Weekday service"

      filtered =
        view
        |> form("#calendar-filter-form", %{"search" => "no such calendar", "status" => "all"})
        |> render_change()

      assert filtered =~ "calendars-filtered-empty"
      assert filtered =~ "No calendars match these filters"
      refute filtered =~ "calendars-first-use-empty"
    end

    test "a first-use empty read is distinct from a failed read", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      conn = log_in_user(conn, user, organization: organization)

      stub_screen(fn _opts -> {:ok, []} end)

      {:ok, view, _html} = live(conn, list_path(version))

      empty = loaded(view)

      assert empty =~ "calendars-first-use-empty"
      assert empty =~ "No calendars in"
      refute empty =~ "Calendars couldn’t be loaded"

      # A connection outage through the adapter seam is never an empty list.
      stub_screen(fn _opts -> {:error, :unavailable} end)

      assert render_click(view, "refresh") =~ "calendars-refreshing"

      retried = loaded(view)

      assert retried =~ "Calendars couldn’t be loaded"
      refute retried =~ "calendars-first-use-empty"
      refute retried =~ "calendars-list-container"

      # Retry recovers through the same seam.
      summary = real_summary(organization, version, "WKD", "Weekday service")
      stub_screen(fn _opts -> {:ok, [summary]} end)

      assert render_click(view, "retry") =~ "calendars-loading"
      assert loaded(view) =~ "Weekday service"
    end

    test "a not-found scope renders no calendar data", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      conn = log_in_user(conn, user, organization: organization)

      stub_screen(fn _opts -> {:error, :not_found} end)

      {:ok, view, _html} = live(conn, list_path(version))
      html = loaded(view)

      assert html =~ "calendars-version-unavailable"
      refute html =~ "calendars-list-container"
      refute html =~ "Calendars couldn’t be loaded"
    end
  end

  describe "navigation" do
    setup :use_real_adapter

    test "both version events navigate only to a permitted published version list", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      conn = log_in_user(conn, user, organization: organization)
      other_version = gtfs_version_fixture(organization.id)

      calendar_attribute_fixture(organization.id, other_version.id, %{
        service_id: "OTHER",
        service_description: "Other version calendar"
      })

      {:ok, view, _html} = live(conn, list_path(version))
      assert loaded(view) =~ "calendars-first-use-empty"

      assert {:error, {:live_redirect, %{to: path}}} =
               render_click(view, "gtfs_version_loaded", %{"version_id" => other_version.id})

      assert path == "/gtfs/#{other_version.id}/calendars"

      {:ok, view, _html} = live(conn, list_path(version))
      assert loaded(view) =~ "calendars-first-use-empty"

      assert {:error, {:live_redirect, %{to: path}}} =
               render_click(view, "switch_gtfs_version", %{"version" => other_version.id})

      assert path == "/gtfs/#{other_version.id}/calendars"
    end

    test "an unpublished or foreign version never navigates", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      conn = log_in_user(conn, user, organization: organization)

      calendar_attribute_fixture(organization.id, version.id, %{
        service_id: "LOCAL",
        service_description: "Local calendar"
      })

      {:ok, view, _html} = live(conn, list_path(version))
      assert loaded(view) =~ "Local calendar"

      assert render_click(view, "switch_gtfs_version", %{"version" => Ecto.UUID.generate()}) =~
               "Local calendar"

      assert render_click(view, "gtfs_version_loaded", %{"version_id" => Ecto.UUID.generate()}) =~
               "Local calendar"

      # The current version is not a permitted switch target either.
      assert render_click(view, "gtfs_version_loaded", %{
               "version_id" => to_string(version.id)
             }) =~ "Local calendar"
    end
  end

  defp every_day_attrs(service_id, start_date, end_date) do
    %{
      service_id: service_id,
      monday: 1,
      tuesday: 1,
      wednesday: 1,
      thursday: 1,
      friday: 1,
      saturday: 1,
      sunday: 1,
      start_date: start_date,
      end_date: end_date
    }
  end

  defp drawer_calendars(organization, version) do
    today = postgres_local_today("Etc/UTC")

    for {service_id, name, start_date, end_date} <- [
          {"ALL_DAYS", "Every day service", Date.add(today, -10), Date.add(today, 30)},
          {"EXTRA", "Extra dates service", Date.add(today, -1), Date.add(today, 60)}
        ] do
      calendar_fixture(
        organization.id,
        version.id,
        every_day_attrs(service_id, start_date, end_date)
      )

      calendar_attribute_fixture(organization.id, version.id, %{
        service_id: service_id,
        service_description: name
      })
    end

    today
  end

  defp scoped_date_count(organization, version) do
    Repo.aggregate(
      from(d in CalendarDate,
        where: d.organization_id == ^organization.id and d.gtfs_version_id == ^version.id
      ),
      :count
    )
  end

  defp checked_services(view, group, service_ids) do
    Enum.filter(service_ids, fn service_id ->
      has_element?(view, "#calendar-date-change-#{group}-#{service_id} input[checked]")
    end)
  end

  describe "cross-calendar date change drawer" do
    setup :use_real_adapter

    test "opens from the toolbar, defaults removal to calendars running on the date and keeps a manual choice",
         %{
           conn: conn,
           user: user,
           organization: organization,
           version: version
         } do
      conn = log_in_user(conn, user, organization: organization)
      today = drawer_calendars(organization, version)
      inside = Date.to_iso8601(Date.add(today, 3))
      outside = Date.to_iso8601(Date.add(today, 40))

      {:ok, view, _html} = live(conn, list_path(version))
      assert loaded(view) =~ "Every day service"

      assert render_click(view, "open_date_change", %{}) =~ "Change service on a date"
      assert view |> render() =~ "calendar-date-change-drawer"

      view
      |> form("#calendar-date-change-form", date_change: %{mode: "single", date: inside})
      |> render_change()

      assert checked_services(view, "remove", ["ALL_DAYS", "EXTRA"]) == ["ALL_DAYS", "EXTRA"]

      # Unchecking both is the reviewer's own choice; changing the date keeps it.
      render_click(view, "date_change_toggle", %{"group" => "remove", "service-id" => "ALL_DAYS"})
      render_click(view, "date_change_toggle", %{"group" => "remove", "service-id" => "EXTRA"})
      assert checked_services(view, "remove", ["ALL_DAYS", "EXTRA"]) == []

      view
      |> form("#calendar-date-change-form", date_change: %{mode: "single", date: outside})
      |> render_change()

      # The reviewer's own choice survives the date change.
      assert checked_services(view, "remove", ["ALL_DAYS", "EXTRA"]) == []

      # A fresh drawer recomputes the default for the only calendar active on that date.
      render_click(view, "close_date_change", %{})
      render_click(view, "open_date_change", %{"date" => outside})
      assert checked_services(view, "remove", ["ALL_DAYS", "EXTRA"]) == ["EXTRA"]
    end

    test "opens from the gap callout with that date and normalizes several dates uniquely", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      conn = log_in_user(conn, user, organization: organization)
      drawer_calendars(organization, version)
      today = postgres_local_today("Etc/UTC")
      first = Date.to_iso8601(Date.add(today, 3))
      second = Date.to_iso8601(Date.add(today, 5))

      {:ok, view, _html} = live(conn, list_path(version))
      assert loaded(view) =~ "Every day service"

      # The gap entry prefills the missing date.
      assert render_click(view, "open_date_change", %{"date" => first}) =~ ~s(value="#{first}")

      view
      |> form("#calendar-date-change-form", date_change: %{mode: "several"})
      |> render_change()

      view
      |> form("#calendar-date-change-form", date_change: %{mode: "several", date_add: first})
      |> render_submit()

      view
      |> form("#calendar-date-change-form", date_change: %{mode: "several", date_add: second})
      |> render_change()

      assert has_element?(view, "#calendar-date-change-dates-chip-#{first}")

      view
      |> form("#calendar-date-change-form", date_change: %{mode: "several", date_add: second})
      |> render_submit()

      view
      |> form("#calendar-date-change-form", date_change: %{mode: "several", date_add: first})
      |> render_submit()

      html = render(view)
      assert html =~ "calendar-date-change-dates-chip-#{first}"
      assert html =~ "calendar-date-change-dates-chip-#{second}"

      # A date chip is removable without touching the stored rows.
      render_click(view, "date_change_remove_date", %{"date" => first})
      refute render(view) =~ "calendar-date-change-dates-chip-#{first}"
      assert scoped_date_count(organization, version) == 0
    end

    test "invalid range cannot apply a prior valid selection", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      today = drawer_calendars(organization, version)

      {:ok, view, _} =
        live(log_in_user(conn, user, organization: organization), list_path(version))

      loaded(view)
      render_click(view, "open_date_change", %{"date" => Date.to_iso8601(today)})

      render_change(view, "date_change_form", %{
        "date_change" => %{
          "mode" => "range",
          "date_from" => Date.to_iso8601(Date.add(today, 2)),
          "date_to" => Date.to_iso8601(today)
        }
      })

      render_click(view, "date_change_review", %{})
      refute has_element?(view, "#calendar-date-change-apply")
      render_click(view, "date_change_apply", %{})
      render(view)
      assert scoped_date_count(organization, version) == 0
    end

    test "rejects reversed ranges, overlapping or missing targets and unknown services without writing",
         %{
           conn: conn,
           user: user,
           organization: organization,
           version: version
         } do
      conn = log_in_user(conn, user, organization: organization)
      today = drawer_calendars(organization, version)
      later = Date.to_iso8601(Date.add(today, 10))
      earlier = Date.to_iso8601(Date.add(today, 2))

      {:ok, view, _html} = live(conn, list_path(version))
      assert loaded(view) =~ "Every day service"
      render_click(view, "open_date_change", %{})

      # A reversed range is refused on its own control.
      view |> form("#calendar-date-change-form", date_change: %{mode: "range"}) |> render_change()

      html =
        view
        |> form("#calendar-date-change-form",
          date_change: %{mode: "range", date_from: later, date_to: earlier}
        )
        |> render_change()

      assert html =~ "Choose a last date on or after the first date."

      # No target at all is refused.
      view
      |> form("#calendar-date-change-form", date_change: %{mode: "single"})
      |> render_change()

      view
      |> form("#calendar-date-change-form", date_change: %{mode: "single", date: later})
      |> render_change()

      # Unchecking every default leaves no target at all.
      render_click(view, "date_change_toggle", %{"group" => "remove", "service-id" => "ALL_DAYS"})
      render_click(view, "date_change_toggle", %{"group" => "remove", "service-id" => "EXTRA"})

      assert render_click(view, "date_change_review", %{}) =~
               "Choose at least one calendar to change."

      # Overlapping groups are refused by name.
      render_click(view, "date_change_toggle", %{"group" => "remove", "service-id" => "ALL_DAYS"})
      render_click(view, "date_change_toggle", %{"group" => "add", "service-id" => "ALL_DAYS"})

      assert render_click(view, "date_change_review", %{}) =~
               "A calendar cannot be stopped and run on the same date."

      # A forged or unknown service ID never becomes a target.
      assert render_click(view, "date_change_toggle", %{
               "group" => "add",
               "service-id" => "FOREIGN_SERVICE"
             }) =~ "That calendar is not in this service version."

      assert scoped_date_count(organization, version) == 0
    end

    test "reviews real changed rows and applies the atomic date change to several calendars", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      conn = log_in_user(conn, user, organization: organization)
      today = drawer_calendars(organization, version)
      holiday = Date.add(today, 3)
      holiday_iso = Date.to_iso8601(holiday)

      {:ok, view, _html} = live(conn, list_path(version))
      assert loaded(view) =~ "Every day service"
      render_click(view, "open_date_change", %{})

      view
      |> form("#calendar-date-change-form", date_change: %{mode: "single", date: holiday_iso})
      |> render_change()

      # Stop the weekday calendar and run the replacement on that exact date.
      render_click(view, "date_change_toggle", %{"group" => "remove", "service-id" => "EXTRA"})
      render_click(view, "date_change_toggle", %{"group" => "add", "service-id" => "EXTRA"})

      html = render_click(view, "date_change_review", %{})
      assert html =~ "calendar-date-change-review-panel"
      assert html =~ "Result after applying"

      # Each line names the calendar, the exact date it changes on and what that means.
      day = Calendar.strftime(holiday, "%a, %b %-d")

      assert [stop_line, run_line] =
               html
               |> text_of("#calendar-date-change-review-lines li")
               |> Enum.map(&squish/1)

      assert stop_line =~ "Stop Every day service stops running on #{day}."
      assert stop_line =~ "affected."
      assert run_line =~ "Run Extra dates service runs on #{day}."
      assert run_line =~ "will run."

      assert [count_line] =
               html |> text_of("#calendar-date-change-review-count") |> Enum.map(&squish/1)

      assert count_line =~ "This changes 2 calendars."
      assert count_line =~ "GTFS: 2 rows change."

      assert render_click(view, "date_change_apply", %{}) =~ "Applied the date change"
      assert render(view) =~ "Applied the date change"
      assert render(view) =~ "rows changed"

      # The stored rows are exactly the authored dates, and the audit is correlated.
      rows =
        Repo.all(
          from(cd in CalendarDate,
            where: cd.organization_id == ^organization.id and cd.gtfs_version_id == ^version.id,
            order_by: [asc: cd.service_id]
          )
        )

      assert [
               %{service_id: "ALL_DAYS", date: ^holiday, exception_type: 2},
               %{service_id: "EXTRA", date: ^holiday, exception_type: 1}
             ] = rows

      assert Enum.all?(rows, &(&1.date == holiday))
    end

    test "a stale review rejects apply, keeps the input and writes nothing", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      conn = log_in_user(conn, user, organization: organization)
      today = drawer_calendars(organization, version)
      holiday = Date.add(today, 3)
      holiday_iso = Date.to_iso8601(holiday)

      {:ok, view, _html} = live(conn, list_path(version))
      assert loaded(view) =~ "Every day service"
      render_click(view, "open_date_change", %{})

      view
      |> form("#calendar-date-change-form", date_change: %{mode: "single", date: holiday_iso})
      |> render_change()

      render_click(view, "date_change_toggle", %{"group" => "remove", "service-id" => "EXTRA"})
      assert render_click(view, "date_change_review", %{}) =~ "Result after applying"

      # Another session changes the same identity after the review was taken.
      Repo.update_all(
        from(ca in CalendarAttribute,
          where: ca.organization_id == ^organization.id and ca.service_id == "ALL_DAYS"
        ),
        set: [service_description: "Renamed in another session"]
      )

      render_click(view, "date_change_apply", %{})
      html = render(view)
      assert html =~ "changed in another session"
      assert html =~ holiday_iso
      assert scoped_date_count(organization, version) == 0
      render_click(view, "date_change_refresh", %{})
      assert checked_services(view, "remove", ["ALL_DAYS", "EXTRA"]) == ["ALL_DAYS"]
      assert render_click(view, "date_change_review", %{}) =~ "Result after applying"
      render_click(view, "date_change_apply", %{})
      assert render(view) =~ "Applied the date change"
      assert scoped_date_count(organization, version) == 1
    end
  end

  describe "design-system list presentation" do
    setup :use_real_adapter

    test "leads each row with its regular days and labels a weekday calendar ending tomorrow from its last service day",
         %{conn: conn, user: user, organization: organization, version: version} do
      conn = log_in_user(conn, user, organization: organization)
      today = postgres_local_today("Etc/UTC")
      expected_end_label = ends_soon_label(last_service_day(Date.add(today, 1)), today)

      calendar_fixture(organization.id, version.id, %{
        service_id: "WEEKD",
        start_date: Date.add(today, -60),
        end_date: Date.add(today, 1)
      })

      calendar_attribute_fixture(organization.id, version.id, %{
        service_id: "WEEKD",
        service_description: "Alpha weekdays"
      })

      # Tomorrow may be a weekend; keep the final service date tomorrow while
      # retaining the regular Mon–Fri presentation this case exercises.
      calendar_date_fixture(organization.id, version.id, %{
        service_id: "WEEKD",
        date: Date.add(today, 1),
        exception_type: 1
      })

      calendar_date_fixture(organization.id, version.id, %{
        service_id: "DATES",
        date: Date.add(today, 30),
        exception_type: 1
      })

      calendar_attribute_fixture(organization.id, version.id, %{
        service_id: "DATES",
        service_description: "Beta dates"
      })

      {:ok, view, _html} = live(conn, list_path(version))
      html = loaded(view)

      assert [weekly, dates] =
               html
               |> text_of(~s(#calendars-list td[data-label="Calendar"]))
               |> Enum.map(&squish/1)

      assert weekly =~ "Alpha weekdays Runs Mon–Fri · WEEKD"
      assert dates =~ "Beta dates Runs on specific dates · DATES"

      assert text_of(html, ~s(#calendars-list td[data-label="Status"])) |> Enum.map(&squish/1) ==
               [expected_end_label, "Not used by trips"]
    end

    test "carries the one way forward in the first-use panel and offers no header actions",
         %{conn: conn, user: user, organization: organization, version: version} do
      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} = live(conn, list_path(version))
      loaded(view)

      assert has_element?(view, "#calendars-first-use-empty #calendars-create")
      refute has_element?(view, "#calendar-date-change")
      refute has_element?(view, "#calendars-workbench")
      assert has_element?(view, "#calendars-first-use-empty", "No calendars in")
    end

    test "swaps the result count for the selection actions while a calendar is ticked",
         %{conn: conn, user: user, organization: organization, version: version} do
      conn = log_in_user(conn, user, organization: organization)

      for {service_id, name} <- [{"ONE", "First calendar"}, {"TWO", "Second calendar"}] do
        calendar_attribute_fixture(organization.id, version.id, %{
          service_id: service_id,
          service_description: name
        })
      end

      {:ok, view, _html} = live(conn, list_path(version))
      loaded(view)

      assert has_element?(view, "#result-count", "2 calendars")
      assert has_element?(view, "#calendar-selection-hint")
      refute has_element?(view, "#calendar-selection-bar")

      render_click(view, "toggle_calendar_selection", %{"service-id" => "ONE"})

      assert has_element?(view, "#calendar-selection-bar #calendar-selection-count", "1 calendar")
      assert has_element?(view, "#calendar-selection-bar #calendar-combine-open[disabled]")
      assert has_element?(view, "#calendar-combine-hint")
      refute has_element?(view, "#result-count")
      refute has_element?(view, "#calendar-selection-hint")

      render_click(view, "clear_calendar_selection", %{})

      assert has_element?(view, "#result-count", "2 calendars")
      refute has_element?(view, "#calendar-selection-bar")
    end
  end
end
