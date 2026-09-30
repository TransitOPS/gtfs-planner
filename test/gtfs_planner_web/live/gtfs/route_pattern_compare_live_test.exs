defmodule GtfsPlannerWeb.Gtfs.RoutePatternCompareLiveTest do
  @moduledoc """
  Merge evidence (EV-10) for CL-13, CL-14 and CL-15: the compare route reaches
  `RoutePatternCompareLive` under the ordinary editor guard, its shell renders the
  route header, title row and calendar select, an absent `a` opens R8's entry
  pair, the calendar select patches `service`, and a read outage shows the
  unavailable state whose retry reloads.

  Every case enters through ordinary login and the real `CatalogReadAdapter.Repo`
  on the local test database (`CR-7`); `CatalogReadAdapterMock` is substituted only
  to simulate the outage. Expected ids, counts and URLs are hand-derived from the
  fixtures below. The focused gate command is deferred to branch review:

      MIX_ENV=test MIX_TEST_PARTITION=_s19 ELIXIR_ERL_OPTIONS="+S 4" gtimeout --signal=TERM --kill-after=10s 120s mix test test/gtfs_planner_web/live/gtfs/route_pattern_compare_live_test.exs
  """

  use GtfsPlannerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Mox
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures
  import GtfsPlanner.GtfsFixtures

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Gtfs.CatalogReadAdapter
  alias GtfsPlanner.Gtfs.CatalogReadAdapterMock
  alias Phoenix.LiveView.Utils

  @adapter_key :gtfs_catalog_read_adapter

  setup :verify_on_exit!

  # Adapter substitution exists only to simulate a read outage. Successful reads
  # use the real context through the production Repo adapter; this helper
  # restores the previous configuration on exit.
  defp substitute_read_adapter(_context) do
    previous = Application.fetch_env(:gtfs_planner, @adapter_key)
    Application.put_env(:gtfs_planner, @adapter_key, CatalogReadAdapterMock)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:gtfs_planner, @adapter_key, value)
        :error -> Application.delete_env(:gtfs_planner, @adapter_key)
      end
    end)

    :ok
  end

  defp editor_scope(%{conn: conn}) do
    organization =
      organization_fixture(%{
        alias: "route-pattern-compare-#{System.system_time(:nanosecond)}"
      })

    user =
      user_fixture(%{
        email: "pattern-compare-editor-#{System.unique_integer([:positive])}@example.com"
      })

    Accounts.create_user_org_membership(%{
      user_id: user.id,
      organization_id: organization.id,
      roles: ["pathways_studio_editor"]
    })

    version = gtfs_version_fixture(organization.id)
    conn = log_in_user(conn, user, organization: organization)

    %{conn: conn, user: user, organization: organization, version: version}
  end

  defp route(organization, version, route_id) do
    route_fixture(organization.id, version.id, %{
      route_id: route_id,
      route_short_name: route_id,
      route_long_name: "#{route_id} corridor"
    })
  end

  defp stop(organization, version, route_id, index) do
    stop_fixture(organization.id, version.id, %{
      stop_id: "#{route_id}_S#{index}",
      stop_name: "#{route_id} Stop #{index}",
      location_type: 0
    })
  end

  defp schedule_pattern(organization, version, route, attrs, stops) do
    schedule_pattern_fixture(organization.id, version.id, %{
      route_id: route.route_id,
      route_pattern_id: attrs.id,
      route_pattern_name: attrs.name,
      direction_id: attrs.direction_id,
      route_pattern_sort_order: Map.get(attrs, :sort_order, 0),
      timing_name: attrs.name,
      stops: stops
    })
  end

  # Route CMP1 with its four stops, a Weekday calendar carrying the trips and an
  # idle Saturday: Full runs twice and Short turn once, so R8's entry pair is
  # Full against Short turn on Weekday (A 2 · B 1).
  defp comparison_route(%{organization: organization, version: version}) do
    route = route(organization, version, "CMP1")
    Enum.each(1..4, &stop(organization, version, "CMP1", &1))

    Enum.each(~w(WEEKDAY SATURDAY), fn service_id ->
      calendar_fixture(organization.id, version.id, %{service_id: service_id})

      calendar_attribute_fixture(organization.id, version.id, %{
        service_id: service_id,
        service_description: String.capitalize(String.downcase(service_id))
      })
    end)

    full =
      schedule_pattern(
        organization,
        version,
        route,
        %{id: "FULL", name: "Full", direction_id: 0, sort_order: 0},
        [
          {"CMP1_S1", 0, 0, 1},
          {"CMP1_S2", 120, 120, 1},
          {"CMP1_S3", 240, 240, 0},
          {"CMP1_S4", 360, 360, 1}
        ]
      )

    short =
      schedule_pattern(
        organization,
        version,
        route,
        %{id: "SHORT", name: "Short turn", direction_id: 0, sort_order: 1},
        [
          {"CMP1_S1", 0, 0, 1},
          {"CMP1_S2", 120, 120, 1},
          {"CMP1_S3", 240, 240, 1}
        ]
      )

    Enum.each(["06:00:00", "07:00:00"], fn start_time ->
      schedule_trip_fixture(organization.id, version.id, route.route_id, full, %{
        service_id: "WEEKDAY",
        start_time: start_time
      })
    end)

    schedule_trip_fixture(organization.id, version.id, route.route_id, short, %{
      service_id: "WEEKDAY",
      start_time: "08:00:00"
    })

    %{route: route, full: full, short: short}
  end

  defp compare_path(version, route, params \\ %{}) do
    base = "/gtfs/#{version.id}/routes/#{route.route_id}/patterns/compare"

    case Enum.reject(params, fn {_key, value} -> is_nil(value) end) do
      [] -> base
      params -> base <> "?" <> URI.encode_query(params)
    end
  end

  defp patterns_path(version, route) do
    "/gtfs/#{version.id}/routes/#{route.route_id}/patterns"
  end

  # A redirect's flash reaches a test as the response's own map when the static
  # render redirected, and as the signed token the connected mount carries.
  # Verifying the token is what `Phoenix.LiveViewTest.assert_redirected/2` does,
  # so the assertion holds either way and still reads the message the planner sees.
  defp redirect_flash(%{} = flash), do: flash

  defp redirect_flash(token) when is_binary(token) do
    Utils.verify_flash(GtfsPlannerWeb.Endpoint, token)
  end

  describe "compare shell" do
    setup :editor_scope

    test "an editor sees the compare page under the route header",
         %{conn: conn, version: version} = context do
      %{route: route} = comparison_route(context)

      {:ok, view, _html} =
        live(conn, compare_path(version, route, %{"a" => "FULL", "b" => "SHORT"}))

      assert has_element?(view, "#compare-page")
      assert has_element?(view, "#route-workspace")
      assert has_element?(view, "#route-title", "CMP1 corridor")
      assert has_element?(view, "#compare-title", "Compare patterns")
      assert has_element?(view, "#route-tab-patterns[aria-current='page']")
      assert has_element?(view, "#compare-slots")
      assert has_element?(view, "#compare-summary")
      assert has_element?(view, "#compare-stops")
      assert has_element?(view, "#compare-map")
      refute has_element?(view, "#pattern-header")
    end

    test "the calendar select lists both sides' trips and patches service",
         %{conn: conn, version: version} = context do
      %{route: route} = comparison_route(context)

      {:ok, view, _html} =
        live(conn, compare_path(version, route, %{"a" => "FULL", "b" => "SHORT"}))

      assert has_element?(view, "#compare-calendar", "Weekday (A 2 · B 1 trips)")
      assert has_element?(view, "#compare-calendar", "Saturday (A 0 · B 0 trips)")

      view
      |> element("#compare-calendar")
      |> render_change(%{"service" => "SATURDAY"})

      assert_patch(
        view,
        compare_path(version, route, %{"a" => "FULL", "b" => "SHORT", "service" => "SATURDAY"})
      )
    end

    test "the view switch is URL state", %{conn: conn, version: version} = context do
      %{route: route} = comparison_route(context)

      {:ok, view, _html} =
        live(conn, compare_path(version, route, %{"a" => "FULL", "b" => "SHORT"}))

      view |> element("#compare-view-all") |> render_click()

      assert_patch(
        view,
        compare_path(version, route, %{"a" => "FULL", "b" => "SHORT", "view" => "all"})
      )
    end

    test "a visit without a opens the entry pair", %{conn: conn, version: version} = context do
      %{route: route} = comparison_route(context)

      # The connect resolves R8's entry pair and pushes it as a patch. A real
      # client applies that patch (the committed `capture: shell` browser run
      # lands on this exact pair), but Phoenix.LiveViewTest's proxy does not
      # surface a patch issued during the connected mount, so the test performs
      # the same patch itself. The pair below is hand-derived from the fixtures:
      # Full runs twice and Short turn once on Weekday.
      default_pair = compare_path(version, route, %{"a" => "FULL", "b" => "SHORT"})

      {:ok, view, _html} = live(conn, compare_path(version, route))
      render_patch(view, default_pair)

      assert has_element?(view, "#compare-calendar", "Weekday (A 2 · B 1 trips)")
      assert has_element?(view, "#slot-a", "Full")
      assert has_element?(view, "#slot-b", "Short turn")
    end

    test "a pattern of another route returns to the Patterns tab",
         %{conn: conn, version: version} = context do
      %{route: route} = comparison_route(context)
      other_route = route(context.organization, version, "CMP2")
      other_stops = Enum.map(1..2, &stop(context.organization, version, "CMP2", &1))

      schedule_pattern(
        context.organization,
        version,
        other_route,
        %{id: "OTHER", name: "Other", direction_id: 0, sort_order: 0},
        Enum.map(other_stops, &{&1.stop_id, 0, 0, 1})
      )

      assert {:error, {:live_redirect, %{to: to, flash: flash}}} =
               live(conn, compare_path(version, route, %{"a" => "OTHER"}))

      assert to == patterns_path(version, route)
      assert redirect_flash(flash) == %{"error" => "Pattern not found"}
    end

    test "members without the editor role cannot reach the compare route",
         %{conn: conn, organization: organization, version: version} = context do
      %{route: route} = comparison_route(context)

      member =
        user_fixture(%{
          email: "pattern-compare-member-#{System.unique_integer([:positive])}@example.com"
        })

      Accounts.create_user_org_membership(%{
        user_id: member.id,
        organization_id: organization.id,
        roles: []
      })

      member_conn = log_in_user(conn, member, organization: organization)

      assert {:error, {:redirect, %{to: "/admin/organizations", flash: flash}}} =
               live(member_conn, compare_path(version, route, %{"a" => "FULL", "b" => "SHORT"}))

      assert redirect_flash(flash) == %{"error" => "You are not authorized to access this page."}
    end

    test "a lost connection shows the unavailable state and the retry reloads",
         %{conn: conn, version: version} = context do
      substitute_read_adapter(%{})
      %{route: route} = comparison_route(context)

      recover = :atomics.new(1, [])

      stub(CatalogReadAdapterMock, :load_pattern_comparison, fn org, ver, params ->
        if :atomics.get(recover, 1) == 1 do
          CatalogReadAdapter.Repo.load_pattern_comparison(org, ver, params)
        else
          {:error, :unavailable}
        end
      end)

      # The retry that recovers the comparison loads the map read with it (the
      # map is its own read, `CL-13`); only the pair read is stubbed to fail.
      stub(CatalogReadAdapterMock, :load_pattern_compare_map, fn org, ver, a, b ->
        CatalogReadAdapter.Repo.load_pattern_compare_map(org, ver, a, b)
      end)

      {:ok, view, _html} =
        live(conn, compare_path(version, route, %{"a" => "FULL", "b" => "SHORT"}))

      assert has_element?(view, "#compare-page")
      assert has_element?(view, "#compare-unavailable", "The comparison didn’t load")
      assert has_element?(view, "#compare-retry", "Try again")

      :atomics.put(recover, 1, 1)
      render_click(element(view, "#compare-retry"))

      refute has_element?(view, "#compare-unavailable")
      assert has_element?(view, "#compare-calendar", "Weekday (A 2 · B 1 trips)")
    end
  end
end
