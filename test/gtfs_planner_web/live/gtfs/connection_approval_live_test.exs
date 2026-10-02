defmodule GtfsPlannerWeb.Gtfs.ConnectionApprovalLiveTest do
  @moduledoc """
  Merge evidence (EV-8) for the Schedules page's connection approval: the exact
  pair, date, minimum and candidate an operator approves, and what the page does
  with a refusal.

  Every expectation is hand-derived from the acceptance cases and the GTFS
  reference rather than from a second call of the code under test: the route 1
  trip calls `CENTRAL-P1` at 09:02:00 and the route 2 trip leaves `HARBOR` at
  09:08:00 on 2026-11-26, the stored type 2 rule naming the parent station
  states 300 seconds, and a supplied candidate of 09:07 is the person's own
  external evidence. The snapshot the page admits is the scope module's own
  envelope, so the assertions read the server's hash rather than a computed one.

  The approval path is the production one: this page's own form posts its own
  strings, `ConnectionComparison.load/3` resolves the pairs against this
  organization and version, and `Scope.with_source_snapshot/2` decides whether
  the whole serialized context fits. A route, trip or stop from another
  organization is refused there, before anything is admitted (AC-1, AC-6, AC-8).
  """
  use GtfsPlannerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Accounts
  alias GtfsPlannerWeb.AgentPanel

  # A Thursday inside the seeded weekday calendar's range.
  @service_date ~D[2026-11-26]
  @service_date_text Date.to_iso8601(@service_date)
  @station "CENTRAL"
  @platform "CENTRAL-P1"
  @harbor "HARBOR"
  @arrival_trip "R1-0902"
  @departure_trip "R2-0908"
  @stored_minimum 300
  @candidate_clock "09:07"
  @candidate_approval "Dispatch sheet 2026-11-26"

  @unavailable_notice "These routes, trips or stops are not part of this version"
  @approved_notice "The connection helper can now read exactly these pairs"

  setup %{conn: conn} do
    organization = organization_fixture(%{alias: unique_alias()})
    user = user_fixture()

    Accounts.create_user_org_membership(%{
      user_id: user.id,
      organization_id: organization.id,
      roles: ["pathways_studio_editor"]
    })

    version = gtfs_version_fixture(organization.id, %{name: "Connections Version"})

    track_sessions()

    organization
    |> seed_version(version)
    |> Map.put(:organization, organization)
    |> Map.put(:user, user)
    |> Map.put(:version, version)
    |> Map.put(:conn, log_in_user(conn, user, organization: organization))
  end

  describe "the approval the helper may read" do
    test "an approved pair, date, minimum and candidate become immutable context", ctx do
      {:ok, view, _html} = live(ctx.conn, schedules_path(ctx))

      assert has_element?(view, "#connection-approval-form")
      assert has_element?(view, "#connection-approve")
      assert has_element?(view, "#schedule-helper-mode-connections")

      submit(view, ctx, pair(ctx))

      assert element(view, "#connection-approval-notice") |> render() =~ @approved_notice

      # What the page shows back is the approval it admitted, not the draft.
      assert element(view, "#connection-approval-date") |> render() =~ @service_date_text
      assert element(view, "#connection-approval-pairs") |> render() =~ "1 pair"
      assert element(view, "#connection-approval-routes") |> render() =~ "R1"
      assert element(view, "#connection-approval-routes") |> render() =~ "R2"
      assert element(view, "#connection-approval-minimums") |> render() =~ "the stored minimum"
      assert element(view, "#connection-approval-candidates") |> render() =~ "1"

      assigns = socket_assigns(view)

      # Approving lands the operator on the helper that owns the source.
      assert assigns.schedule_helper_mode == "connections"
      assert assigns.agent_pack_id == "connections"

      assert %{kind: "connections", payload: payload, digest: digest} =
               assigns.agent_context.source_snapshot

      assert digest =~ ~r/\A[0-9a-f]{64}\z/
      assert payload["schema_version"] == 1
      assert payload["service_date"] == @service_date_text
      assert payload["approved_route_ids"] == ["R1", "R2"]
      assert payload["base_digest"] =~ ~r/\A[0-9a-f]{64}\z/

      assert [approved] = payload["pairs"]
      assert approved["id"] == "pair-1"

      assert approved["from"] == %{
               "route_id" => row_id(ctx.from_route),
               "trip_id" => row_id(ctx.arrival_trip),
               "stop_id" => @platform,
               "stop_sequence" => 1,
               "service_date_offset" => 0
             }

      assert approved["to"] == %{
               "route_id" => row_id(ctx.to_route),
               "trip_id" => row_id(ctx.departure_trip),
               "stop_id" => @harbor,
               "stop_sequence" => 1,
               "service_date_offset" => 0
             }

      assert approved["minimum"] == %{"origin" => "stored"}

      # The feed's own trip names travel beside the rows, so the page and the
      # helper report a connection in identifiers this feed uses.
      assert payload["trips"] == [
               %{"id" => row_id(ctx.arrival_trip), "trip_id" => @arrival_trip},
               %{"id" => row_id(ctx.departure_trip), "trip_id" => @departure_trip}
             ]

      # The candidate is the person's own external clock, labelled by them.
      assert [candidate] = payload["candidates"]
      assert candidate["pair_id"] == "pair-1"
      assert candidate["origin"] == "supplied"
      assert candidate["arrival"] == @candidate_clock
      assert candidate["departure"] == @candidate_clock
      assert candidate["approval"] == @candidate_approval

      # The conversation key the page shows is the one the session binds.
      shown =
        view
        |> element("#connection-approval-conversation")
        |> render()
        |> String.replace(~r/<[^>]+>/, "")
        |> String.trim()

      digest_value = AgentPanel.context_digest(view_socket(view))
      assert shown == String.slice(digest_value, 0, 12) <> "…"
    end

    test "a supplied minimum is admitted as supplied evidence beside its approval", ctx do
      {:ok, view, _html} = live(ctx.conn, schedules_path(ctx))

      supplied =
        pair(ctx,
          minimum: %{
            "origin" => "supplied",
            "seconds" => to_string(@stored_minimum + 60),
            "approval" => "Approved timetable sheet"
          }
        )

      submit(view, ctx, supplied)

      assert %{payload: payload} = socket_assigns(view).agent_context.source_snapshot
      assert [%{"minimum" => minimum}] = payload["pairs"]

      assert minimum == %{
               "origin" => "supplied",
               "seconds" => @stored_minimum + 60,
               "approval" => "Approved timetable sheet"
             }

      assert element(view, "#connection-approval-minimums") |> render() =~
               "a supplied minimum of 360 seconds"
    end

    test "the approved source opens the connections helper and nothing is written", ctx do
      {:ok, view, _html} = live(ctx.conn, schedules_path(ctx))

      submit(view, ctx, pair(ctx))

      counts = row_counts(ctx)

      view |> element("#agent-helper-open") |> render_click()

      assert has_element?(view, "#agent-panel")
      # The panel admitted this context, so it did not take its own refusal.
      refute has_element?(view, "#agent-notice")
      assert socket_assigns(view).agent_pack_id == "connections"

      # Approval prepares nothing: it reads, and this page wrote no row.
      assert row_counts(ctx) == counts
    end
  end

  describe "refusals" do
    test "a receiving route from another organization is refused and the draft stays", ctx do
      {:ok, view, _html} = live(ctx.conn, schedules_path(ctx))

      submit(view, ctx, pair(ctx, to_trip: ctx.foreign_trip.trip_id))

      assert element(view, "#connection-approval-notice") |> render() =~ @unavailable_notice
      refute has_element?(view, "#connection-approval-receipt")

      assigns = socket_assigns(view)
      assert assigns.connection_approval == nil
      assert assigns.agent_context.source_snapshot == nil

      # The draft is the operator's own text and it is still on screen.
      assert has_element?(
               view,
               ~s(input#connection-pair-1-to-trip[value="#{ctx.foreign_trip.trip_id}"])
             )

      assert has_element?(view, ~s(input#connection-pair-1-from-stop[value="#{@platform}"]))
    end

    test "a malformed draft is refused before any connection is read", ctx do
      {:ok, view, _html} = live(ctx.conn, schedules_path(ctx))

      submit(view, ctx, pair(ctx, to_route: ""))

      assert element(view, "#connection-approval-notice") |> render() =~ "Each side needs a route"
      assert socket_assigns(view).agent_context.source_snapshot == nil
      assert has_element?(view, "#connection-approval-form")
    end

    test "a whole approved context above the byte limit refuses with fewer than 500 pairs", ctx do
      {:ok, view, _html} = live(ctx.conn, schedules_path(ctx))

      submit(view, ctx, pair(ctx, candidate_approval: String.duplicate("a", 70_000)))

      assert element(view, "#connection-approval-notice") |> render() =~
               "larger than the helper can hold"

      # One pair is nowhere near the pair ceiling, so the byte bound is what
      # refused this, and it says so rather than claiming a count problem.
      assert socket_assigns(view).connection_pair_limit > 1
      assert socket_assigns(view).agent_context.source_snapshot == nil
      assert has_element?(view, "#connection-approval-form")
    end
  end

  describe "invalidation" do
    test "an edited approval drops the receipt and the source but keeps the draft", ctx do
      {:ok, view, _html} = live(ctx.conn, schedules_path(ctx))

      submit(view, ctx, pair(ctx))
      assert socket_assigns(view).agent_context.source_snapshot != nil

      edited = pair(ctx, service_date: "2026-11-27")

      view
      |> form("#connection-approval-form", %{"connection" => edited})
      |> render_change()

      assigns = socket_assigns(view)

      refute has_element?(view, "#connection-approval-receipt")
      refute has_element?(view, "#connection-approval-notice")
      assert assigns.connection_approval == nil
      assert assigns.connection_context == nil
      assert assigns.agent_context.source_snapshot == nil

      # The operator's edit is still the draft on screen.
      assert has_element?(view, ~s(input#connection-service-date[value="2026-11-27"]))
      assert has_element?(view, ~s(input#connection-pair-1-to-stop[value="#{@harbor}"]))
    end

    test "another route on the same version drops an approval made on this one", ctx do
      {:ok, view, _html} = live(ctx.conn, schedules_path(ctx))

      submit(view, ctx, pair(ctx))
      assert socket_assigns(view).agent_context.source_snapshot != nil

      render_patch(view, schedules_path(ctx, route: ctx.other_route))

      assigns = socket_assigns(view)
      assert assigns.connection_approval == nil
      assert assigns.agent_context.source_snapshot == nil
      refute has_element?(view, "#connection-approval-receipt")
    end

    test "a native reload of the schedule drops the approval with its evidence", ctx do
      {:ok, view, _html} = live(ctx.conn, schedules_path(ctx))

      submit(view, ctx, pair(ctx))
      assert socket_assigns(view).agent_context.source_snapshot != nil

      # A native write and the reload it takes: the page's rows moved, so the
      # approval that was made against them cannot still be the evidence.
      render_click(view, "open_delete_trip", %{"trip" => row_id(ctx.arrival_trip)})
      render_click(view, "confirm_delete", %{})

      assigns = socket_assigns(view)
      assert assigns.connection_approval == nil
      assert assigns.agent_context.source_snapshot == nil
      refute has_element?(view, "#connection-approval-receipt")
    end
  end

  describe "the helper this page offers" do
    test "a mode change keeps the native schedule draft and the approval draft", ctx do
      {:ok, view, _html} = live(ctx.conn, schedules_path(ctx))

      # The page's own calendar filter, which is not the helper's to touch.
      view |> form("#schedule-calendar-form", %{"service_id" => "WEEK"}) |> render_change()

      submit(view, ctx, pair(ctx))

      view |> element("#schedule-helper-mode-service_queries") |> render_click()

      assigns = socket_assigns(view)
      assert assigns.schedule_helper_mode == "service_queries"
      assert assigns.agent_pack_id == "service_queries"
      # The schedule questions helper reads the plain route context, and the
      # connections source is not input to it.
      assert assigns.agent_context.source_snapshot == nil
      # Nothing the operator typed went with the switch.
      assert view |> element("#calendar-filter") |> render() =~ "WEEK"
      assert has_element?(view, ~s(input#connection-pair-1-from-stop[value="#{@platform}"]))
      assert has_element?(view, ~s(input#connection-pair-1-to-stop[value="#{@harbor}"]))

      # Switching back rebinds the source this page already admitted rather than
      # asking for the same approval twice.
      view |> element("#schedule-helper-mode-connections") |> render_click()

      assigns = socket_assigns(view)
      assert assigns.schedule_helper_mode == "connections"
      assert %{kind: "connections"} = assigns.agent_context.source_snapshot
    end

    test "a forged mode changes nothing on this page or in the panel", ctx do
      {:ok, view, _html} = live(ctx.conn, schedules_path(ctx))

      before = socket_assigns(view)

      render_click(view, "schedule_helper_mode", %{"mode" => "transfers"})

      after_assigns = socket_assigns(view)
      assert after_assigns.schedule_helper_mode == before.schedule_helper_mode
      assert after_assigns.agent_pack_id == before.agent_pack_id
      assert after_assigns.agent_context == before.agent_context
      assert has_element?(view, "#schedule-helper-mode")
    end
  end

  ## Fixtures

  # Two routes on one weekday service: route 1 arrives at the platform at 09:02
  # and route 2 leaves the harbor at 09:08, so the pair is a real connection on
  # the seeded date. A third route carries the page's own load for the
  # navigation case, and a fourth organization's route and trip are the foreign
  # rows a forged event names.
  defp seed_version(organization, version) do
    agency_fixture(organization.id, version.id, %{
      agency_id: "CONN",
      agency_timezone: "America/New_York"
    })

    calendar_fixture(organization.id, version.id, %{service_id: "WEEK"})
    calendar_attribute_fixture(organization.id, version.id, %{service_id: "WEEK"})

    stop_fixture(organization.id, version.id, %{
      stop_id: @station,
      stop_name: "Central Station",
      location_type: 1
    })

    stop_fixture(organization.id, version.id, %{
      stop_id: @platform,
      stop_name: "Central Platform 1",
      location_type: 0
    })

    stop_fixture(organization.id, version.id, %{stop_id: @harbor, stop_name: "Harbor Yards"})

    from_route = route_fixture(organization.id, version.id, %{route_id: "R1", agency_id: "CONN"})
    to_route = route_fixture(organization.id, version.id, %{route_id: "R2", agency_id: "CONN"})

    arrival_trip =
      timed_trip(organization, version, from_route, @arrival_trip, @platform, "09:02:00")

    departure_trip =
      timed_trip(organization, version, to_route, @departure_trip, @harbor, "09:08:00")

    other_route =
      route_fixture(organization.id, version.id, %{route_id: "R3", agency_id: "CONN"})

    _other_trip = timed_trip(organization, version, other_route, "R3-1010", @platform, "10:10:00")

    # The stored rule names the parent station, which is what lets it cover the
    # platform, and it states the 300 seconds the comparison is measured against.
    transfer_fixture(organization.id, version.id, %{
      from_stop_id: @station,
      to_stop_id: @harbor,
      transfer_type: 2,
      min_transfer_time: @stored_minimum
    })

    foreign_organization = organization_fixture(%{alias: unique_alias()})
    foreign_version = gtfs_version_fixture(foreign_organization.id)

    foreign_route =
      route_fixture(foreign_organization.id, foreign_version.id, %{
        route_id: "FOREIGN",
        agency_id: "CONN"
      })

    foreign_trip =
      trip_fixture(foreign_organization.id, foreign_version.id, foreign_route.route_id, %{
        trip_id: "FOREIGN-0902",
        service_id: "WEEK",
        direction_id: 0
      })

    %{
      from_route: from_route,
      to_route: to_route,
      arrival_trip: arrival_trip,
      departure_trip: departure_trip,
      other_route: other_route,
      foreign_organization: foreign_organization,
      foreign_version: foreign_version,
      foreign_route: foreign_route,
      foreign_trip: foreign_trip
    }
  end

  defp timed_trip(organization, version, route, trip_id, stop_id, clock) do
    pattern =
      schedule_pattern_fixture(organization.id, version.id, %{
        route_id: route.route_id,
        direction_id: 0,
        route_pattern_name: "#{trip_id} pattern",
        stops: [{stop_id, 0, 0, 1}]
      })

    schedule_trip_fixture(organization.id, version.id, route.route_id, pattern, %{
      service_id: "WEEK",
      trip_id: trip_id,
      start_time: clock,
      trip_headsign: "Test"
    })
  end

  defp unique_alias,
    do: "conn-approve-" <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)

  ## The form this page posts

  defp pair(ctx, opts \\ []) do
    to_route = Keyword.get(opts, :to_route, ctx.to_route)
    to_trip = Keyword.get(opts, :to_trip, ctx.departure_trip)

    %{
      "service_date" => Keyword.get(opts, :service_date, @service_date_text),
      "pairs" => %{
        "0" => %{
          "id" => "pair-1",
          "from" => endpoint(ctx.from_route, ctx.arrival_trip, @platform),
          "to" => endpoint(to_route, to_trip, @harbor),
          "minimum" =>
            Keyword.get(opts, :minimum, %{"origin" => "stored", "seconds" => "", "approval" => ""}),
          "candidate" => %{
            "arrival" => @candidate_clock,
            "departure" => @candidate_clock,
            "approval" => Keyword.get(opts, :candidate_approval, @candidate_approval)
          }
        }
      }
    }
  end

  # What the operator types is what this feed calls the route and the trip, and
  # this page resolves both inside its own version before they become a reference.
  defp endpoint(route, trip, stop_id) do
    %{
      "route_id" => label(route),
      "trip_id" => label(trip),
      "stop_id" => stop_id,
      "stop_sequence" => "1",
      "service_date_offset" => "0"
    }
  end

  # The trip fixture hands back the trip with its stop times and frequencies, so
  # the row's own id is one level down; a forged submission names one by id.
  # A fixture row is the struct itself; the trip fixture wraps it with its stop
  # times and frequencies, so its row is one level down.
  defp row_id(%{trip: trip}), do: trip.id
  defp row_id(%{id: id}), do: id

  # The feed's own names, which is what an operator reads on this page.
  defp label(%{trip: trip}), do: trip.trip_id
  defp label(%{route_id: route_id}), do: route_id
  defp label(value), do: value

  defp submit(view, _ctx, params) do
    view |> form("#connection-approval-form", %{"connection" => params}) |> render_submit()
  end

  ## Views and paths

  defp schedules_path(ctx, opts \\ []) do
    route = Keyword.get(opts, :route, ctx.from_route)
    query = Keyword.get(opts, :query, %{})
    path = "/gtfs/#{ctx.version.id}/routes/#{route.route_id}/schedules"

    case URI.encode_query(query) do
      "" -> path
      encoded -> path <> "?" <> encoded
    end
  end

  defp socket_assigns(view), do: :sys.get_state(view.pid).socket.assigns

  defp view_socket(view), do: :sys.get_state(view.pid).socket

  defp row_counts(ctx) do
    import Ecto.Query

    GtfsPlanner.Repo.aggregate(
      from(t in GtfsPlanner.Gtfs.Transfer,
        where: t.organization_id == ^ctx.organization.id and t.gtfs_version_id == ^ctx.version.id
      ),
      :count
    )
  end

  # Sessions are started under the application's own supervisor and outlive the
  # test socket, so every session this file opened is terminated here.
  defp track_sessions do
    before = session_pids()

    on_exit(fn ->
      for pid <- session_pids(), pid not in before do
        DynamicSupervisor.terminate_child(GtfsPlanner.Agents.SessionSupervisor, pid)
      end
    end)
  end

  defp session_pids do
    GtfsPlanner.Agents.SessionSupervisor
    |> DynamicSupervisor.which_children()
    |> Enum.map(fn {_id, pid, _type, _modules} -> pid end)
  end
end
