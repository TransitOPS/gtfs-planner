defmodule GtfsPlanner.Gtfs.StopEditingApplyMoveTest do
  @moduledoc """
  `StopEditing.apply_move/4` (EV-17, AC-16).

  A move is the one editor command that can leave the map disagreeing with
  itself, so what is under test is mostly what the command *refuses* and what
  it commits anyway. A review answered against stale data is not applied. A far
  move is not applied until the editor says whether this is the same stop. And
  a pattern whose linked trips disagree with its visits does not take the
  coordinates down with it: the stop moves, the line is reported stale.

  Every case asserts the mutation that must *not* happen as well as the one
  that must, because "nothing was written" is the property most of these
  guards exist to provide and the easiest to get wrong by accident.

  Fingerprints are real: each case takes the review's own value rather than a
  literal, so a fingerprint that stopped covering what it claims to cover
  would fail here rather than quietly agreeing with itself.

  Routing goes through the real `StreetRouting` composition with only the HTTP
  boundary faked (`Req.Test`, `config/test.exs:134`).
  """

  use ExUnit.Case, async: false

  import Ecto.Query
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias Ecto.Adapters.SQL.Sandbox
  alias GtfsPlanner.Accounts.UserOrgMembership
  alias GtfsPlanner.Gtfs.Alignments
  alias GtfsPlanner.Gtfs.AlignmentSegment
  alias GtfsPlanner.Gtfs.AuditContext
  alias GtfsPlanner.Gtfs.ChangeLog
  alias GtfsPlanner.Gtfs.Route
  alias GtfsPlanner.Gtfs.RoutePattern
  alias GtfsPlanner.Gtfs.RoutePatternStop
  alias GtfsPlanner.Gtfs.Shape
  alias GtfsPlanner.Gtfs.Stop
  alias GtfsPlanner.Gtfs.StopEditing
  alias GtfsPlanner.Gtfs.StopTime
  alias GtfsPlanner.Gtfs.TimedPattern
  alias GtfsPlanner.Gtfs.Trip
  alias GtfsPlanner.Organizations
  alias GtfsPlanner.Organizations.Organization
  alias GtfsPlanner.Repo

  @routing_owner GtfsPlanner.StreetRouting.Geoapify
  @test_key "test-apply-move-key-6c2d9e1b4a8f"

  @stop_lat 44.6210
  @stop_lon -124.0530
  @metres_per_degree 111_320.0

  # Past `StopPlacement.move_band/2`'s far threshold, which is 100 m.
  @far_m 330.0
  # Past the correction band, inside it.
  @review_m 13.7

  setup do
    Req.Test.set_req_test_to_shared(%{})

    original_key = Application.get_env(:gtfs_planner, :geoapify_api_key)
    Application.put_env(:gtfs_planner, :geoapify_api_key, @test_key)

    on_exit(fn ->
      if is_nil(original_key) do
        Application.delete_env(:gtfs_planner, :geoapify_api_key)
      else
        Application.put_env(:gtfs_planner, :geoapify_api_key, original_key)
      end

      Req.Test.set_req_test_to_private(%{})
    end)

    fixture = staged_fixture()

    on_exit(fn -> cleanup_fixture(fixture) end)

    {:ok, fixture: fixture}
  end

  describe "apply_move/4 with lines: :redraw" do
    test "commits the coordinates, rematerializes P and reports Q stale", context do
      fixture = context.fixture
      stub_routing(200)

      review = review(fixture)
      before = snapshot(fixture)

      assert {:ok, result} = apply_move(fixture, review, lines: :redraw)

      # The stop moved. `numeric(9, 6)` rounds to about 11 cm, which is the
      # column's resolution rather than the assertion's tolerance.
      assert_in_delta Decimal.to_float(result.stop.stop_lat), moved_lat(@review_m), 0.000_001
      assert result.stop.stop_lon == Decimal.from_float(@stop_lon)

      # P was redrawn and Q was not. Reported as UUIDs so the caller can act
      # on them; the reasons are the review's, already computed in step 14.
      assert [p] = result.redrawn
      assert p == pattern_id(fixture, "P")
      assert [q] = result.stale
      assert q == pattern_id(fixture, "Q")

      # Q's rows survived its neighbour's redraw, and P's did not.
      assert shape_points(fixture, "SHAPE-Q") == before.shape_points["SHAPE-Q"]
      refute shape_points(fixture, "SHAPE-P") == before.shape_points["SHAPE-P"]

      p = pattern(fixture, "P")

      assert unboxed(fn -> Alignments.resolve(p).status.export end) == :current
    end

    test "commits even though Q is blocked — the stop is still moved", context do
      fixture = context.fixture
      stub_routing(200)

      review = review(fixture)
      stop_before = point_of_stop(fixture)

      assert {:ok, result} = apply_move(fixture, review, lines: :redraw)

      # The point of the case: `materialize_pattern!/4` rolls the whole
      # transaction back on blockers, so a command that let it run would
      # return an error here and leave the stop exactly where it was.
      refute_in_delta elem(point_of_stop(fixture), 1), elem(stop_before, 1), 0.000_01
      assert_in_distance(elem(point_of_stop(fixture), 1) - elem(stop_before, 1), @review_m, 0.5)
      assert result.stale != []
    end

    test "a :keep move writes only the coordinates and reports every pattern stale", context do
      fixture = context.fixture
      stub_routing(200)

      review = review(fixture)
      before = snapshot(fixture)

      assert {:ok, result} = apply_move(fixture, review, lines: :keep)

      assert result.redrawn == []
      # Every pattern the review listed, not just the blocked one: the editor
      # chose to keep the lines, so every one of them is now stale.
      assert Enum.sort(result.stale) ==
               Enum.sort([pattern_id(fixture, "P"), pattern_id(fixture, "Q")])

      # The geometry is byte-identical. A :keep that still redrew would be
      # saving a decision the editor did not make.
      assert segment_points(fixture, "1330", "1434") == before.segment_points["1330-1434"]
      assert shape_points(fixture, "SHAPE-P") == before.shape_points["SHAPE-P"]
    end
  end

  describe "apply_move/4 guards" do
    test "a fingerprint computed before another editor saved is :stale_review", context do
      fixture = context.fixture
      stub_routing(200)

      review = review(fixture)

      # Another editor saved the stop between the review and the apply. The
      # fingerprint covers `updated_at` precisely so this is caught.
      unboxed(fn ->
        Stop
        |> where([s], s.id == ^fixture.stops["1434"].id)
        |> Repo.update_all(set: [stop_desc: "edited elsewhere"])
      end)

      before = snapshot(fixture)

      assert {:error, :stale_review} = apply_move(fixture, review, lines: :redraw)

      assert unboxed(fn -> snapshot(fixture) end) == before
    end

    test "a fingerprint computed before a segment moved is :stale_review", context do
      fixture = context.fixture
      stub_routing(200)

      review = review(fixture)

      unboxed(fn ->
        from(s in AlignmentSegment,
          where:
            s.organization_id == ^fixture.organization.id and
              s.gtfs_version_id == ^fixture.version.id and
              s.from_stop_id == "1330" and
              s.to_stop_id == "1434"
        )
        |> Repo.update_all(set: [points: [[-124.06, 44.63]], lock_version: 99])
      end)

      before = snapshot(fixture)

      assert {:error, :stale_review} = apply_move(fixture, review, lines: :redraw)
      assert unboxed(fn -> snapshot(fixture) end) == before
    end

    test "a far move with no answer is :answer_required and changes nothing", context do
      fixture = context.fixture
      stub_routing(200)

      review = far_review(fixture)
      before = snapshot(fixture)

      assert review.band == :far
      assert {:error, :answer_required} = apply_move(fixture, review, lines: :redraw)

      assert unboxed(fn -> snapshot(fixture) end) == before
    end

    test "a far move answered :same saves", context do
      fixture = context.fixture
      stub_routing(200)

      review = far_review(fixture)

      assert {:ok, result} = apply_move(fixture, review, lines: :keep, answer: :same)

      assert_in_delta Decimal.to_float(result.stop.stop_lat), moved_lat(@far_m), 0.000_001
    end

    test "a far move answered :new is refused and changes nothing", context do
      fixture = context.fixture
      stub_routing(200)

      review = far_review(fixture)
      before = snapshot(fixture)

      # `:new` is an answer, not a failure: the editor is saying this is a
      # different stop, and the caller starts an add at the pin instead.
      assert {:error, :new_stop} = apply_move(fixture, review, lines: :redraw, answer: :new)

      assert unboxed(fn -> snapshot(fixture) end) == before
    end

    test "a stop the actor may not edit is forbidden", context do
      fixture = context.fixture
      stub_routing(200)

      review = review(fixture)
      before = snapshot(fixture)

      stranger = unboxed(fn -> user_fixture(%{email: "move-stranger-#{stamp()}@example.com"}) end)

      audit = %{fixture.audit | actor_id: stranger.id, actor_email: stranger.email}

      assert {:error, :forbidden} =
               apply_move(fixture, review, [lines: :redraw], audit)

      assert unboxed(fn -> snapshot(fixture) end) == before
    end

    test "a stop in another version is not found", context do
      fixture = context.fixture
      stub_routing(200)

      review = review(fixture)
      before = snapshot(fixture)

      elsewhere = unboxed(fn -> organization_fixture(%{alias: "move-elsewhere-#{stamp()}"}) end)

      # A real second organization the same actor also edits, so the case
      # tests the *scoping* rather than the authorization: a stop the actor
      # cannot edit is refused earlier, and for a different reason.
      unboxed(fn ->
        {:ok, _membership} =
          Organizations.add_user_to_organization(fixture.actor.id, elsewhere.id, [
            "pathways_studio_editor"
          ])
      end)

      on_exit(fn ->
        unboxed(fn ->
          Repo.delete_all(from m in UserOrgMembership, where: m.organization_id == ^elsewhere.id)

          Repo.delete_all(from o in Organization, where: o.id == ^elsewhere.id)
        end)
      end)

      assert {:error, :not_found} =
               apply_move(fixture, review, [lines: :redraw], %{
                 fixture.audit
                 | organization_id: elsewhere.id
               })

      assert unboxed(fn -> snapshot(fixture) end) == before
    end
  end

  describe "apply_move/4 audit" do
    test "records the move distance and the lines choice", context do
      fixture = context.fixture
      stub_routing(200)

      review = review(fixture)

      assert {:ok, _result} = apply_move(fixture, review, lines: :keep)

      entry =
        unboxed(fn ->
          Repo.one(
            from(log in ChangeLog,
              where:
                log.organization_id == ^fixture.organization.id and
                  log.gtfs_version_id == ^fixture.version.id and
                  log.entity_type == "stop" and
                  log.entity_id == ^fixture.stops["1434"].id and
                  log.action == "updated",
              order_by: [desc: log.inserted_at],
              limit: 1,
              select: log
            )
          )
        end)

      assert entry.actor_id == fixture.actor.id

      # `build_changed_fields/4` diffs every audited field into a from/to pair,
      # so the move provenance arrives nested under `"to"`. The two coordinate
      # fields carry the same shape and are the only thing that distinguishes
      # a 13.7 m correction from a 330 m relocation, so the distance is what
      # the history view actually has to read.
      assert %{"from" => nil, "to" => move} = entry.changed_fields["move"]
      assert %{"distance_m" => distance, "lines" => "keep"} = move
      assert_in_delta distance, @review_m, 0.5
    end

    test "a refused move writes no audit entry", context do
      fixture = context.fixture
      stub_routing(200)

      review = far_review(fixture)

      assert {:error, :answer_required} = apply_move(fixture, review, lines: :redraw)

      assert unboxed(fn ->
               Repo.one(
                 from(log in ChangeLog,
                   where:
                     log.organization_id == ^fixture.organization.id and
                       log.gtfs_version_id == ^fixture.version.id and
                       log.entity_type == "stop" and
                       log.action == "updated"
                 )
               )
             end) == nil
    end
  end

  # --- drivers

  # The review carries the exact point it was taken at, and the apply is given
  # that same point. Deriving the apply's coordinates back from the review's
  # *reported distance* would differ in the last bits — `StopPlacement`'s
  # haversine does not round-trip through degrees — and the fingerprint would
  # refuse every move. That the fingerprint refuses a *different* point is the
  # guard under test, not an accident of float arithmetic.
  defp apply_move(fixture, review, opts, audit \\ nil) do
    options =
      opts
      |> Keyword.put(:fingerprint, review.fingerprint)
      |> Keyword.put(:suggestions, review.suggestions)
      |> Keyword.put_new(:lines, :redraw)
      |> Map.new()

    unboxed(fn ->
      StopEditing.apply_move(
        fixture.stops["1434"].id,
        %{
          "stop_lat" => elem(review.point, 1),
          "stop_lon" => elem(review.point, 0),
          "stop_name" => "Main St"
        },
        options,
        audit || fixture.audit
      )
    end)
  end

  defp review(fixture) do
    take_review(fixture, {moved_lon(), moved_lat(@review_m)})
  end

  defp far_review(fixture) do
    take_review(fixture, {moved_lon(), moved_lat(@far_m)})
  end

  defp take_review(fixture, point) do
    review =
      unboxed(fn ->
        {:ok, review} = StopEditing.move_review(fixture.stops["1434"].id, point, fixture.audit)

        review
      end)

    Map.put(review, :point, point)
  end

  # Everything a move could touch, in one comparable value. A guard that rolled
  # back the coordinates but left an audit row behind would change this.
  #
  # The whole read is one `unboxed_run`: the helpers below are private to it
  # and must not each check a connection out, which the sandbox forbids
  # nesting. The shape and segment maps read *values*, not just row existence,
  # because a rollback that restored a row with different bytes would pass a
  # count-based snapshot.
  defp snapshot(fixture) do
    unboxed(fn ->
      scope = [fixture.organization.id, fixture.version.id]

      %{
        stops: stamps(Stop, scope),
        segments: stamps(AlignmentSegment, scope),
        shapes: stamps(Shape, scope),
        patterns: stamps(RoutePattern, scope),
        occurrences: stamps(RoutePatternStop, scope),
        stop_times: stamps(StopTime, scope),
        trips: stamps(Trip, scope),
        routes: stamps(Route, scope),
        timings: stamps(TimedPattern, scope),
        logs: stamps(ChangeLog, scope),
        segment_points: segment_point_map(scope),
        shape_points: shape_point_map(scope)
      }
    end)
  end

  defp segment_point_map(scope) do
    from(s in AlignmentSegment,
      where: s.organization_id in ^scope and s.gtfs_version_id in ^scope,
      select: {s.from_stop_id, s.to_stop_id, s.points}
    )
    |> Repo.all()
    |> Map.new(fn {from_id, to_id, points} -> {"#{from_id}-#{to_id}", points} end)
  end

  defp shape_point_map(scope) do
    from(s in Shape,
      where: s.organization_id in ^scope and s.gtfs_version_id in ^scope,
      order_by: [asc: s.shape_id, asc: s.shape_pt_sequence],
      select: {s.shape_id, s.shape_pt_lon, s.shape_pt_lat}
    )
    |> Repo.all()
    |> Enum.group_by(&elem(&1, 0), fn {_, lon, lat} ->
      [Decimal.to_float(lon), Decimal.to_float(lat)]
    end)
  end

  defp segment_points(fixture, from_id, to_id) do
    unboxed(fn ->
      from(s in AlignmentSegment,
        where:
          s.organization_id == ^fixture.organization.id and
            s.gtfs_version_id == ^fixture.version.id and
            s.from_stop_id == ^from_id and
            s.to_stop_id == ^to_id,
        select: s.points
      )
      |> Repo.one()
    end)
  end

  defp shape_points(fixture, shape_id) do
    unboxed(fn ->
      from(s in Shape,
        where:
          s.organization_id == ^fixture.organization.id and
            s.gtfs_version_id == ^fixture.version.id and
            s.shape_id == ^shape_id,
        order_by: [asc: s.shape_pt_sequence],
        select: {s.shape_pt_lon, s.shape_pt_lat}
      )
      |> Repo.all()
      |> Enum.map(fn {lon, lat} -> [Decimal.to_float(lon), Decimal.to_float(lat)] end)
    end)
  end

  defp pattern_id(fixture, route_pattern_id) do
    unboxed(fn -> pattern_row(fixture, route_pattern_id).id end)
  end

  defp pattern_row(fixture, route_pattern_id) do
    Repo.one!(
      from(p in RoutePattern,
        where:
          p.organization_id == ^fixture.organization.id and
            p.gtfs_version_id == ^fixture.version.id and
            p.route_pattern_id == ^route_pattern_id
      )
    )
  end

  defp pattern(fixture, route_pattern_id) do
    unboxed(fn -> pattern_row(fixture, route_pattern_id) end)
  end

  defp stop_lat(fixture) do
    unboxed(fn ->
      Repo.one!(from(s in Stop, where: s.id == ^fixture.stops["1434"].id, select: s.stop_lat))
      |> Decimal.to_float()
    end)
  end

  # The stop's stored position, read back from the database rather than from
  # a struct: `numeric(9, 6)` rounds to about 11 cm, and that rounding is part
  # of what these cases are asserting against.
  defp point_of_stop(fixture) do
    unboxed(fn ->
      {lon, lat} =
        Repo.one!(
          from(s in Stop,
            where: s.id == ^fixture.stops["1434"].id,
            select: {s.stop_lon, s.stop_lat}
          )
        )

      {Decimal.to_float(lon), Decimal.to_float(lat)}
    end)
  end

  # Metres, not degrees. The move is 13.7 m; asserting on the raw latitude
  # difference would pass for a move of any size under a degree and fail for a
  # correct one under a metre.
  defp assert_in_distance(lat_delta, metres, tolerance) do
    assert_in_delta lat_delta * @metres_per_degree, metres, tolerance
  end

  defp stamps(ChangeLog, [organization_id, gtfs_version_id]) do
    Repo.all(
      from log in ChangeLog,
        where:
          log.organization_id == ^organization_id and
            log.gtfs_version_id == ^gtfs_version_id,
        order_by: [asc: log.id],
        select: {log.id, log.inserted_at}
    )
  end

  defp stamps(schema, [organization_id, gtfs_version_id]) do
    Repo.all(
      from row in schema,
        where:
          row.organization_id == ^organization_id and
            row.gtfs_version_id == ^gtfs_version_id,
        order_by: field(row, :id),
        select: {row.id, row.inserted_at, row.updated_at}
    )
  end

  # --- routing double

  defp stub_routing(status) do
    Req.Test.stub(@routing_owner, fn conn ->
      Plug.Conn.send_resp(
        Plug.Conn.put_resp_content_type(conn, "application/json"),
        status,
        Jason.encode!(routing_response([[[-124.0530, 44.6205], [-124.0530, 44.6215]]]))
      )
    end)
  end

  defp routing_response(legs) do
    %{
      "type" => "FeatureCollection",
      "features" => [
        %{
          "type" => "Feature",
          "properties" => %{"mode" => "bus"},
          "geometry" => %{"type" => "MultiLineString", "coordinates" => legs}
        }
      ]
    }
  end

  # --- fixture

  # P is redrawable; Q shares P's pair and has a linked trip that disagrees
  # with its visits. Deliberately the smallest fixture that can show a move
  # committing while a line stays stale.
  defp staged_fixture do
    unboxed(fn ->
      organization = organization_fixture(%{alias: "apply-move-#{stamp()}"})
      version = gtfs_version_fixture(organization.id)
      actor = add_actor(organization.id)

      audit = %AuditContext{
        organization_id: organization.id,
        gtfs_version_id: version.id,
        actor_id: actor.id,
        actor_email: actor.email
      }

      stops = seed_stops(organization.id, version.id)

      route = named_route(organization.id, version.id, "1")

      # Saved geometry, deliberately not the routing double's answer, so a
      # redraw that wrote nothing would be visible.
      segment(organization.id, version.id, "1330", "1434", [[-124.06, 44.63]])
      segment(organization.id, version.id, "1434", "1355", [[-124.04, 44.63]])

      p = pattern_fixture(organization.id, version.id, route, "P", ["1330", "1434"], "SHAPE-P")

      q =
        pattern_fixture(
          organization.id,
          version.id,
          route,
          "Q",
          ["1330", "1434", "1355"],
          "SHAPE-Q"
        )

      calendar = calendar_fixture(organization.id, version.id, %{service_id: "WEEKDAYS"})

      seed_trip(organization.id, version.id, p, "TRIP-P-1", ["1330", "1434"], calendar.service_id)

      # Q's trip has two stop times for three visits.
      seed_trip(organization.id, version.id, q, "TRIP-Q-1", ["1330", "1434"], calendar.service_id)

      for shape_id <- ["SHAPE-P", "SHAPE-Q"] do
        seed_shape(organization.id, version.id, shape_id)
      end

      %{
        organization: organization,
        version: version,
        actor: actor,
        audit: audit,
        stops: stops
      }
    end)
  end

  defp seed_stops(organization_id, gtfs_version_id) do
    Map.new(
      [
        {"1330", "Cedar St", 44.6200},
        {"1434", "Main St", @stop_lat},
        {"1355", "Elm St", 44.6220}
      ],
      fn {id, name, lat} ->
        {id,
         stop_fixture(organization_id, gtfs_version_id, %{
           stop_id: id,
           stop_name: name,
           stop_lat: Decimal.from_float(lat),
           stop_lon: Decimal.from_float(@stop_lon)
         })}
      end
    )
  end

  # `Trip.changeset/2` casts neither `route_pattern_id` nor
  # `pattern_derivation_state`, and the database pairs `"linked"` with a
  # non-null `timed_pattern_id`, so all three are written here.
  defp seed_trip(organization_id, gtfs_version_id, pattern_row, trip_id, stop_ids, service_id) do
    trip_fixture(organization_id, gtfs_version_id, pattern_row.route_id, %{
      trip_id: trip_id,
      service_id: service_id
    })
    |> put_on_pattern(pattern_row)

    stop_ids
    |> Enum.with_index(1)
    |> Enum.each(fn {stop_id, position} ->
      stop_time_fixture(organization_id, gtfs_version_id, trip_id, stop_id, %{
        stop_sequence: position
      })
    end)
  end

  defp put_on_pattern(trip, pattern) do
    timing = timed_pattern_fixture(pattern)

    trip
    |> Ecto.Changeset.change(
      route_pattern_id: pattern.route_pattern_id,
      pattern_derivation_state: "linked",
      timed_pattern_id: timing.id
    )
    |> Repo.update!()
  end

  defp seed_shape(organization_id, gtfs_version_id, shape_id) do
    now = DateTime.utc_now()

    {1, _} =
      Repo.insert_all(Shape, [
        %{
          organization_id: organization_id,
          gtfs_version_id: gtfs_version_id,
          shape_id: shape_id,
          shape_pt_lon: Decimal.from_float(-124.05),
          shape_pt_lat: Decimal.from_float(44.60),
          shape_pt_sequence: 1,
          inserted_at: now,
          updated_at: now
        }
      ])

    :ok
  end

  defp add_actor(organization_id) do
    actor = user_fixture(%{email: "apply-move-#{stamp()}@example.com"})

    {:ok, _membership} =
      Organizations.add_user_to_organization(actor.id, organization_id, [
        "pathways_studio_editor"
      ])

    actor
  end

  defp named_route(organization_id, gtfs_version_id, route_id) do
    route_fixture(organization_id, gtfs_version_id, %{route_short_name: route_id})
    |> Ecto.Changeset.change(route_id: route_id)
    |> Repo.update!()
  end

  defp segment(organization_id, gtfs_version_id, from_id, to_id, points) do
    %AlignmentSegment{
      organization_id: organization_id,
      gtfs_version_id: gtfs_version_id,
      from_stop_id: from_id,
      to_stop_id: to_id
    }
    |> AlignmentSegment.changeset(%{points: points})
    |> Repo.insert!()
  end

  # `RoutePattern.changeset/2` does not cast `shape_id`, so a pattern meant to
  # own a line gets one written directly.
  defp pattern_fixture(
         organization_id,
         gtfs_version_id,
         route,
         route_pattern_id,
         stop_ids,
         shape_id
       ) do
    pattern =
      route_pattern_fixture(organization_id, gtfs_version_id, %{
        route_pattern_id: route_pattern_id,
        route_id: route.route_id,
        direction_id: 0,
        headsign: "To #{route_pattern_id}"
      })
      |> Ecto.Changeset.change(shape_id: shape_id)
      |> Repo.update!()

    stop_ids
    |> Enum.with_index(1)
    |> Enum.each(fn {stop_id, position} ->
      route_pattern_stop_fixture(pattern, stop_id, position)
    end)

    pattern
  end

  defp moved_lat(metres), do: @stop_lat + metres / @metres_per_degree
  defp moved_lon, do: @stop_lon

  defp unboxed(fun), do: Sandbox.unboxed_run(Repo, fun)

  defp stamp, do: System.system_time(:nanosecond)

  # Tables in dependency order. `trips.timed_pattern_id` is a RESTRICT foreign
  # key, so the trips have to go before the timings they point at.
  @cleanup_tables [
    ChangeLog,
    AlignmentSegment,
    StopTime,
    RoutePatternStop,
    Stop,
    Trip,
    TimedPattern,
    RoutePattern,
    Route
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
    end)
  end
end
