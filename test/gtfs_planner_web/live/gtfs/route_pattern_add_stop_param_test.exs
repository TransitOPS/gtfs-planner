defmodule GtfsPlannerWeb.Gtfs.RoutePatternAddStopParamTest do
  @moduledoc """
  Tests for `?task=stops&add_stop=<stop_id>`.

  The Map view's created panel offers "Add it to a pattern", and that link is
  what brings an editor here: a stop was created, it needs to be on a route, and
  the link carries which stop. So the parameter has to do the one thing the
  editor would otherwise have to do by hand — put the stop in the list.

  Three cases carry the claim and each has a failure it would hide:

    * a stop halfway between two staged stops is staged **between them**, at the
      position its own coordinates imply rather than at the end of the list. A
      link that appended would be a link an editor has to fix;
    * a stop of another version stages **nothing**. `lookup_eligible_stop/2` is
      scoped to the organization and the version, so a foreign stop resolves to
      nothing and the list is untouched — the stale-link case;
    * re-rendering with the same value stages it **once**. `handle_params/3` runs
      on a patch as well as on a mount, and a LiveView that staged on every
      params change would grow a list nobody asked for.

  Staging is not saving: the existing Save and review applies it, and these
  tests assert nothing about what that review does.
  """
  use GtfsPlannerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Accounts

  setup do
    organization = organization_fixture()
    user = user_fixture()

    Accounts.create_user_org_membership(%{
      user_id: user.id,
      organization_id: organization.id,
      roles: ["pathways_studio_editor"]
    })

    version = gtfs_version_fixture(organization.id)

    route =
      route_fixture(organization.id, version.id, %{
        route_id: "R1",
        route_short_name: "1",
        route_long_name: "Main"
      })

    # Three stops up a line running north, one every 0.01° of latitude, which
    # is about 1.11 km. The new stop sits between the first and the second, so
    # the cheapest position is index 1 and not 0 and not 3.
    stops =
      Enum.map(1..3, fn index ->
        stop_fixture(organization.id, version.id, %{
          stop_id: "S#{index}",
          stop_name: "Stop #{index}",
          location_type: 0,
          stop_lat: Decimal.new(to_string(44.6 + index * 0.01)),
          stop_lon: Decimal.new("-124.05")
        })
      end)

    pattern =
      route_pattern_fixture(organization.id, version.id, %{
        route_id: route.route_id,
        route_pattern_id: "NB",
        route_pattern_name: "Northbound",
        direction_id: 0,
        headsign: "Newport"
      })

    stops
    |> Enum.with_index(1)
    |> Enum.each(fn {stop, position} ->
      route_pattern_stop_fixture(pattern, stop.stop_id, position)
    end)

    new_stop =
      stop_fixture(organization.id, version.id, %{
        stop_id: "NEW",
        stop_name: "New Curb Stop",
        location_type: 0,
        stop_lat: Decimal.new("44.61500"),
        stop_lon: Decimal.new("-124.05")
      })

    %{
      conn: log_in_user(build_conn(), user, organization: organization),
      organization: organization,
      version: version,
      route: route,
      pattern: pattern,
      stops: stops,
      new_stop: new_stop
    }
  end

  defp path(version, route, pattern, query) do
    "/gtfs/#{version.id}/routes/#{route.route_id}/patterns/#{pattern.route_pattern_id}?#{query}"
  end

  defp staged(_ctx, view) do
    :sys.get_state(view.pid).socket.assigns.staged_occurrences |> Enum.map(& &1.stop_id)
  end

  describe "the stop's own position" do
    test "a stop between the first and the second is staged between them", ctx do
      {:ok, view, _html} =
        live(ctx.conn, path(ctx.version, ctx.route, ctx.pattern, "task=stops&add_stop=NEW"))

      assert staged(ctx, view) == ["S1", "NEW", "S2", "S3"]

      # `insert_after` is the form's own vocabulary — "after N stops" — so the
      # answer is 1, not the zero-based index the placement function returns.
      assert :sys.get_state(view.pid).socket.assigns.insert_after == "1"

      # The rendered list agrees with the assign, so the editor sees the
      # position rather than only the code holding it.
      assert has_element?(view, "#pattern-stops", "New Curb Stop")

      html = render(view)

      assert index(html, "S1") < index(html, "NEW")
      assert index(html, "NEW") < index(html, "S2")
    end

    test "a stop past the last one is staged at the end, not after the second", ctx do
      last =
        stop_fixture(ctx.organization.id, ctx.version.id, %{
          stop_id: "TAIL",
          stop_name: "Tail Stop",
          location_type: 0,
          stop_lat: Decimal.new("44.65000"),
          stop_lon: Decimal.new("-124.05")
        })

      {:ok, view, _html} =
        live(
          ctx.conn,
          path(ctx.version, ctx.route, ctx.pattern, "task=stops&add_stop=#{last.stop_id}")
        )

      assert staged(ctx, view) == ["S1", "S2", "S3", "TAIL"]
      assert :sys.get_state(view.pid).socket.assigns.insert_after == "3"
    end

    test "a stop before the first is staged at the front", ctx do
      head =
        stop_fixture(ctx.organization.id, ctx.version.id, %{
          stop_id: "HEAD",
          stop_name: "Head Stop",
          location_type: 0,
          stop_lat: Decimal.new("44.59000"),
          stop_lon: Decimal.new("-124.05")
        })

      {:ok, view, _html} =
        live(
          ctx.conn,
          path(ctx.version, ctx.route, ctx.pattern, "task=stops&add_stop=#{head.stop_id}")
        )

      assert staged(ctx, view) == ["HEAD", "S1", "S2", "S3"]

      # Zero is the form's `-1`: "before the first stop". Storing "0" would
      # have fallen through `insert_index/2` to "at the end" and put the stop
      # at the bottom of the route.
      assert :sys.get_state(view.pid).socket.assigns.insert_after == "-1"
    end

    test "the flash says the stop was staged and not saved", ctx do
      {:ok, view, _html} =
        live(ctx.conn, path(ctx.version, ctx.route, ctx.pattern, "task=stops&add_stop=NEW"))

      assert render(view) =~ "is staged at its place along the route"
    end
  end

  describe "a route that bends" do
    # Up 300 m, then east 300 m: B1 at the foot, B2 at the corner, B3 at the
    # east end. At 44.6° a degree of longitude is about 79.2 km, so 0.003786° is
    # 300 m east and 0.002695° of latitude is 300 m north.
    setup ctx do
      pattern =
        route_pattern_fixture(ctx.organization.id, ctx.version.id, %{
          route_id: ctx.route.route_id,
          route_pattern_id: "BENT",
          route_pattern_name: "Bent",
          direction_id: 1,
          headsign: "Harbor"
        })

      [{"B1", 0.0, 0.0}, {"B2", 0.002695, 0.0}, {"B3", 0.002695, 0.003786}]
      |> Enum.with_index(1)
      |> Enum.each(fn {{stop_id, north, east}, position} ->
        stop_fixture(ctx.organization.id, ctx.version.id, %{
          stop_id: stop_id,
          stop_name: "Bend #{stop_id}",
          location_type: 0,
          stop_lat: Decimal.from_float(44.6 + north),
          stop_lon: Decimal.from_float(-124.05 + east)
        })

        route_pattern_stop_fixture(pattern, stop_id, position)
      end)

      %{bent: pattern}
    end

    test "a stop 100 m from the first leg and 150 m from the second is staged on the first",
         ctx do
      # 100 m east and 150 m up from B1: the first leg is the nearer street. The
      # stop's latitude and longitude are measured in the same metre grid as the
      # route's, so the east-west and north-south metres are not mixed up.
      beside_first_leg =
        stop_fixture(ctx.organization.id, ctx.version.id, %{
          stop_id: "BESIDE",
          stop_name: "Beside First Leg",
          location_type: 0,
          stop_lat: Decimal.from_float(44.6 + 0.001348),
          stop_lon: Decimal.from_float(-124.05 + 0.001262)
        })

      {:ok, view, _html} =
        live(
          ctx.conn,
          path(
            ctx.version,
            ctx.route,
            ctx.bent,
            "task=stops&add_stop=#{beside_first_leg.stop_id}"
          )
        )

      assert staged(ctx, view) == ["B1", "BESIDE", "B2", "B3"]
      assert :sys.get_state(view.pid).socket.assigns.insert_after == "1"
    end
  end

  describe "a stop this version does not hold" do
    test "another version's stop stages nothing and says nothing", ctx do
      other_version = gtfs_version_fixture(ctx.organization.id)

      foreign =
        stop_fixture(ctx.organization.id, other_version.id, %{
          stop_id: "FOREIGN",
          stop_name: "Another Version's Stop",
          location_type: 0,
          stop_lat: Decimal.new("44.61500"),
          stop_lon: Decimal.new("-124.05")
        })

      {:ok, view, _html} =
        live(
          ctx.conn,
          path(ctx.version, ctx.route, ctx.pattern, "task=stops&add_stop=#{foreign.stop_id}")
        )

      # A stale link is not an editor's mistake worth a message; it leaves the
      # stop list exactly as it was.
      assert staged(ctx, view) == ["S1", "S2", "S3"]
      refute render(view) =~ "Another Version&#39;s Stop"
    end

    test "a stop ID no version holds stages nothing", ctx do
      {:ok, view, _html} =
        live(ctx.conn, path(ctx.version, ctx.route, ctx.pattern, "task=stops&add_stop=NOSUCH"))

      assert staged(ctx, view) == ["S1", "S2", "S3"]
    end
  end

  describe "once per value" do
    test "a patch carrying the same add_stop does not stage it twice", ctx do
      {:ok, view, _html} =
        live(ctx.conn, path(ctx.version, ctx.route, ctx.pattern, "task=stops&add_stop=NEW"))

      assert staged(ctx, view) == ["S1", "NEW", "S2", "S3"]

      render_patch(view, path(ctx.version, ctx.route, ctx.pattern, "task=stops&add_stop=NEW"))

      assert staged(ctx, view) == ["S1", "NEW", "S2", "S3"]
    end

    test "a link to a different stop stages that one instead", ctx do
      {:ok, view, _html} =
        live(ctx.conn, path(ctx.version, ctx.route, ctx.pattern, "task=stops&add_stop=NEW"))

      assert staged(ctx, view) == ["S1", "NEW", "S2", "S3"]

      # S1 already exists on this pattern, so staging it again is refused by
      # `stage_stop/2` — which is the point: the second link is answered and
      # the list is not grown.
      render_patch(view, path(ctx.version, ctx.route, ctx.pattern, "task=stops&add_stop=S1"))

      assert staged(ctx, view) == ["S1", "NEW", "S2", "S3"]
    end
  end

  describe "the parameters that do not ask for staging" do
    test "no add_stop leaves the list alone", ctx do
      {:ok, view, _html} =
        live(ctx.conn, path(ctx.version, ctx.route, ctx.pattern, "task=stops"))

      assert staged(ctx, view) == ["S1", "S2", "S3"]
    end

    test "another task does not stage the stop", ctx do
      {:ok, view, _html} =
        live(ctx.conn, path(ctx.version, ctx.route, ctx.pattern, "task=timings&add_stop=NEW"))

      assert staged(ctx, view) == ["S1", "S2", "S3"]
    end
  end

  defp index(html, needle) do
    {position, _length} = :binary.match(html, needle)
    position
  end
end
