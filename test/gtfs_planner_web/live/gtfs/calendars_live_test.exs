defmodule GtfsPlannerWeb.Gtfs.CalendarsLiveTest do
  use GtfsPlannerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Mox
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures
  import GtfsPlanner.GtfsFixtures

  alias GtfsPlanner.Accounts
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

  defp stub_catalog(result_fn) do
    stub(CatalogReadAdapterMock, :load_calendar_catalog, fn _org, _version, opts ->
      result_fn.(opts)
    end)

    stub(CatalogReadAdapterMock, :load_calendar_feed_status, fn _org, _version ->
      {:ok, %{today: @fixed_today, gaps: []}}
    end)
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
      assert html =~ ~s{<span class="tabular-nums">2</span>}
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
      refute html =~ "Change service on a date"
      refute html =~ "Add break"
      refute html =~ "Duplicate calendar"
      refute html =~ "Delete calendar"
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

      stub_catalog(fn _opts -> {:ok, [summary]} end)

      {:ok, view, static_html} = live(conn, list_path(version))

      assert static_html =~ "calendars-loading"
      refute static_html =~ "calendars-list-container"

      assert render(view) =~ "Weekday service"

      refreshing = render_click(view, "refresh")

      assert refreshing =~ "calendars-refreshing"
      assert refreshing =~ "Refreshing calendars"
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

      stub_catalog(fn _opts -> {:ok, []} end)

      {:ok, view, _html} = live(conn, list_path(version))

      empty = loaded(view)

      assert empty =~ "calendars-first-use-empty"
      assert empty =~ "No calendars yet"
      refute empty =~ "Calendars couldn’t be loaded"

      # A connection outage through the adapter seam is never an empty list.
      stub_catalog(fn _opts -> {:error, :unavailable} end)

      assert render_click(view, "refresh") =~ "calendars-refreshing"

      retried = loaded(view)

      assert retried =~ "Calendars couldn’t be loaded"
      refute retried =~ "calendars-first-use-empty"
      refute retried =~ "calendars-list-container"

      # Retry recovers through the same seam.
      summary = real_summary(organization, version, "WKD", "Weekday service")
      stub_catalog(fn _opts -> {:ok, [summary]} end)

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

      stub_catalog(fn _opts -> {:error, :not_found} end)

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
end
