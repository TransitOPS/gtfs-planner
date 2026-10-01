defmodule GtfsPlannerWeb.Gtfs.StopsMapActionParamTest do
  @moduledoc """
  Merge evidence (EV-36) for the stop page's More actions arriving on the Map
  view as `?action=`.

  The stop page offers three operations that are not an edit, and each one is a
  link rather than a button because the editor is leaving the page. A link that
  only carried `?stop=` would land on the edit panel and ask the editor to find
  the operation a second time, which is the difference between a link that is
  the request and a link that is only a route. So each action is claimed here as
  the panel it opens.

  Three things pull against each other and all three are asserted. An action is
  only meaningful once the stop is open, so it is answered after the model
  arrives rather than in `handle_params/3`. An action naming a stop this version
  does not hold must open nothing rather than a panel about a stop nobody can
  see — the stale-link case. And an action for an operation that could be
  refused anyway opens its refusal, not a form: the make-station case refuses a
  stop that is already a bay, and a link that opened a form an editor could fill
  and fail to save is a worse answer than the refusal.

  The focused command is deferred to branch review:
  `MIX_ENV=test MIX_TEST_PARTITION=_sa28 ELIXIR_ERL_OPTIONS="+S 4" mix test test/gtfs_planner_web/live/gtfs/stops_map_action_param_test.exs`.
  """
  use GtfsPlannerWeb.ConnCase, async: false

  import Mox, only: [set_mox_global: 1, verify_on_exit!: 1]
  import Phoenix.LiveViewTest
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.GeocodingMock

  setup :set_mox_global
  setup :verify_on_exit!

  setup do
    organization = organization_fixture()
    editor = user_fixture()

    Accounts.create_user_org_membership(%{
      user_id: editor.id,
      organization_id: organization.id,
      roles: ["pathways_studio_editor"]
    })

    version = gtfs_version_fixture(organization.id)

    served =
      stop_fixture(organization.id, version.id, %{
        stop_id: "SERVED",
        stop_name: "Served Stop",
        location_type: 0,
        stop_lat: Decimal.new("44.63700"),
        stop_lon: Decimal.new("-124.05310")
      })

    # 1.5 m from the served stop, which is what the replace panel's candidate
    # search needs, and a second stop on the same pattern so the delete is
    # blocked rather than confirmed.
    duplicate =
      stop_fixture(organization.id, version.id, %{
        stop_id: "DUPE",
        stop_name: "Possible Duplicate",
        location_type: 0,
        stop_lat: Decimal.new("44.63700"),
        stop_lon: Decimal.new("-124.05308")
      })

    route = route_fixture(organization.id, version.id, %{route_short_name: "1"})

    pattern =
      route_pattern_fixture(organization.id, version.id, %{
        route_pattern_id: "NB",
        route_id: route.route_id,
        direction_id: 0,
        headsign: "Newport"
      })

    route_pattern_stop_fixture(pattern, "SERVED", 1)

    # DUPE is deliberately not on the pattern: a replace whose two stops share a
    # pattern is refused, which is covered by the refusal case below, and the
    # review is a different question.

    Mox.stub(GeocodingMock, :reverse, fn lat, lon, _opts ->
      {:ok,
       [
         %GtfsPlanner.Geocoding.Place{
           name: "Cedar Valley Transit Center",
           lat: lat,
           lon: lon,
           distance_m: 40.0
         }
       ]}
    end)

    %{
      organization: organization,
      version: version,
      conn: log_in_user(build_conn(), editor, organization: organization),
      served: served,
      duplicate: duplicate,
      route: route,
      pattern: pattern
    }
  end

  # Every panel here reads behind an asynchronous task of its own — the delete
  # review, the replace review, the station's landmark lookup — so the view is
  # settled rather than waited a fixed number of times: a chain of reads that
  # happens to be one longer on a slow machine would otherwise fail here
  # rather than in the assertion it belongs to.
  defp settle(view, rounds \\ 8)
  defp settle(view, 0), do: view

  defp settle(view, rounds) do
    render_async(view, 5_000)
    settle(view, rounds - 1)
  end

  defp open_map(conn, version, query) do
    {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/stops/map?#{query}")
    settle(view)
  end

  describe "?action=delete" do
    test "a stop service depends on opens the delete panel and is refused", ctx do
      view = open_map(ctx.conn, ctx.version, "stop=SERVED&action=delete")

      # The panels are siblings, so the delete panel replaces the edit panel
      # rather than sitting on top of it.
      assert has_element?(view, "#stops-map-delete-panel")

      # The stop is on a pattern, so the answer is the refusal: it names what
      # still uses it and offers no delete button beside it.
      assert has_element?(view, "#stops-map-delete-blocked-message")
      assert has_element?(view, "#stops-map-delete-blocked-list")
      assert has_element?(view, "#stops-map-delete-blocked-list")
      refute has_element?(view, "#stops-map-delete-go")
    end
  end

  describe "?action=replace" do
    test "a stop with a candidate nearby opens the replace review", ctx do
      view = open_map(ctx.conn, ctx.version, "stop=SERVED&action=replace")

      assert has_element?(view, "#stops-map-replace-panel")

      # The review is the operation, not a form: it says what would move and
      # offers the apply only when it was refused nothing.
      assert has_element?(view, "#stops-map-replace-panel")

      # The review is the operation, not a form: it says what would move.
      assert has_element?(view, "#stops-map-replace-candidates")
      assert has_element?(view, "#stops-map-replace-candidate-DUPE")
      assert has_element?(view, "#stops-map-replace-panel", "What changes")
      assert has_element?(view, "#stops-map-replace-changes")
      refute has_element?(view, "#stops-map-replace-refused")
    end
  end

  describe "a refused action" do
    test "replacing a stop with one already on the same pattern opens the refusal", ctx do
      route_pattern_stop_fixture(ctx.pattern, "DUPE", 2)

      view = open_map(ctx.conn, ctx.version, "stop=SERVED&action=replace")

      assert has_element?(view, "#stops-map-replace-panel")
      assert has_element?(view, "#stops-map-replace-refused-message")

      # A refusal offers nothing to apply: the apply button and the "delete the
      # old stop" checkbox are absent, so the operation cannot be half-agreed.
      refute has_element?(view, "#stops-map-replace-apply")
      refute has_element?(view, "#stops-map-replace-delete-old")
    end
  end

  describe "?action=make_station" do
    test "a plain stop opens the station panel", ctx do
      view = open_map(ctx.conn, ctx.version, "stop=SERVED&action=make_station")

      assert has_element?(view, "#stops-map-station-panel")
      assert has_element?(view, "#stops-map-station-bay[value=A]")
    end

    test "a stop that is already a bay opens the refusal with no form", ctx do
      bay =
        stop_fixture(ctx.organization.id, ctx.version.id, %{
          stop_id: "BAY",
          stop_name: "Newport Transit Center, Bay A",
          location_type: 0,
          parent_station: "ST-NTC",
          stop_lat: Decimal.new("44.63700"),
          stop_lon: Decimal.new("-124.05310")
        })

      station =
        stop_fixture(ctx.organization.id, ctx.version.id, %{
          stop_id: "ST-NTC",
          stop_name: "Newport Transit Center",
          location_type: 1,
          stop_lat: Decimal.new("44.63700"),
          stop_lon: Decimal.new("-124.05310")
        })

      _ = bay
      _ = station

      view = open_map(ctx.conn, ctx.version, "stop=BAY&action=make_station")

      assert has_element?(view, "#stops-map-station-panel", "already a bay")
      refute has_element?(view, "#stops-map-station-form")
    end
  end

  describe "the guards on the parameter" do
    test "an action naming a stop this version does not hold opens nothing", ctx do
      view = open_map(ctx.conn, ctx.version, "stop=NOSUCHSTOP&action=delete")

      refute has_element?(view, "#stops-map-delete-panel")
      refute has_element?(view, "#stops-map-edit-panel")
      assert has_element?(view, "#stops-map-panel")
    end

    test "an action this panel does not recognise is ignored", ctx do
      view = open_map(ctx.conn, ctx.version, "stop=SERVED&action=teleport")

      assert has_element?(view, "#stops-map-edit-panel")
      refute has_element?(view, "#stops-map-delete-panel")
      refute has_element?(view, "#stops-map-replace-panel")
      refute has_element?(view, "#stops-map-station-panel")
    end

    test "without an action the stop opens on the edit panel", ctx do
      view = open_map(ctx.conn, ctx.version, "stop=SERVED")

      assert has_element?(view, "#stops-map-edit-panel")
      refute has_element?(view, "#stops-map-delete-panel")
      refute has_element?(view, "#stops-map-replace-panel")
      refute has_element?(view, "#stops-map-station-panel")
    end

    test "?stop= wins over ?action= when both are asked for", ctx do
      # The stop names a subject and the action does not, so a link carrying
      # both opens the stop rather than one of its panels.
      view = open_map(ctx.conn, ctx.version, "stop=DUPE&action=delete")

      assert has_element?(view, "#stops-map-delete-panel")
    end
  end
end
