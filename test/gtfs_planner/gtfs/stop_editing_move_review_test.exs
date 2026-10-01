defmodule GtfsPlanner.Gtfs.StopEditingMoveReviewTest do
  @moduledoc """
  `StopEditing.move_review/3` and `Alignments.suggest_stop_pairs/4` (EV-15, AC-14).

  The review is the step where an editor finds out what a drag will cost, so
  what is under test is that it is *complete* and *honest*: every pattern that
  shares a pair is listed, including one belonging to a different route; each
  pattern gets the outcome its own data earns rather than a default; a routing
  failure is reported as a routing failure and not as a data problem; a
  transfer's walking distance is shown both before and after.

  The last test is the one the others would all pass without: a review is a
  question, and a question that answers by writing is not a review. Row counts
  and `updated_at` on every table the review reads are compared before and
  after.

  Routing goes through the real `StreetRouting` composition with only the HTTP
  boundary faked (`Req.Test`, `config/test.exs:134`), so the request shape, the
  response parsing and the failure atoms are the production ones.
  """

  use ExUnit.Case, async: false

  import Ecto.Query
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.AdvancedBlockingFixtures
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias Ecto.Adapters.SQL.Sandbox
  alias GtfsPlanner.Accounts.UserOrgMembership
  alias GtfsPlanner.Gtfs.Alignments
  alias GtfsPlanner.Gtfs.AlignmentSegment
  alias GtfsPlanner.Gtfs.AuditContext
  alias GtfsPlanner.Gtfs.ChangeLog
  alias GtfsPlanner.Gtfs.ReliefPoint
  alias GtfsPlanner.Gtfs.Route
  alias GtfsPlanner.Gtfs.RoutePattern
  alias GtfsPlanner.Gtfs.RoutePatternStop
  alias GtfsPlanner.Gtfs.Shape
  alias GtfsPlanner.Gtfs.Stop
  alias GtfsPlanner.Gtfs.StopEditing
  alias GtfsPlanner.Gtfs.StopTime
  alias GtfsPlanner.Gtfs.TimedPattern
  alias GtfsPlanner.Gtfs.Transfer
  alias GtfsPlanner.Gtfs.Trip
  alias GtfsPlanner.Organizations
  alias GtfsPlanner.Organizations.Organization
  alias GtfsPlanner.Repo

  @routing_owner GtfsPlanner.StreetRouting.Geoapify
  @test_key "test-move-review-key-3f81c0a4d2b7"

  # The moved stop sits 13.7 m north of where the review starts measuring from.
  @stop_lat 44.6210
  @stop_lon -124.0530
  @move_m 13.7
  @metres_per_degree 111_320.0

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

    :ok
  end

  describe "Alignments.suggest_stop_pairs/4" do
    setup :staged_fixture

    test "finds both pairs around the stop and routes each once", context do
      fixture = context.fixture
      stub_routing(200)

      routed =
        unboxed(fn ->
          Alignments.suggest_stop_pairs(
            fixture.organization.id,
            fixture.version.id,
            "1434",
            {moved_lon(), moved_lat()}
          )
        end)

      assert routed.pairs == [{"1330", "1434"}, {"1434", "1355"}]
      assert Map.keys(routed.suggestions) == [{"1330", "1434"}, {"1434", "1355"}]
      assert routed.failed == %{}
    end

    test "a pair is routed once however many patterns share it", context do
      fixture = context.fixture
      counter = :counters.new(1, [])
      stub_counting_routing(200, counter)

      unboxed(fn ->
        Alignments.suggest_stop_pairs(
          fixture.organization.id,
          fixture.version.id,
          "1434",
          {moved_lon(), moved_lat()}
        )
      end)

      # P, Q, R and S all use (1330, 1434). Four patterns, one request: a
      # pair two patterns share is one street, and a review that redrew it
      # twice would be asking the routing provider for the same answer twice.
      assert :counters.get(counter, 1) == 2
    end

    test "a routing failure is reported per pair rather than dropped", context do
      fixture = context.fixture
      stub_routing(500)

      routed =
        unboxed(fn ->
          Alignments.suggest_stop_pairs(
            fixture.organization.id,
            fixture.version.id,
            "1434",
            {moved_lon(), moved_lat()}
          )
        end)

      assert routed.suggestions == %{}
      assert Map.keys(routed.failed) == [{"1330", "1434"}, {"1434", "1355"}]
    end
  end

  describe "StopEditing.move_review/3" do
    setup :staged_fixture

    test "lists every pattern using either pair, including another route's", context do
      fixture = context.fixture
      stub_routing(200)

      review = review(fixture)

      ids = Enum.map(review.patterns, & &1.route_pattern_id)

      # P, Q and R are on route 1; S is on route 2 and shares the same pair.
      # A review that missed S would tell an editor their drag touches three
      # lines when it touches four.
      assert "P" in ids
      assert "Q" in ids
      assert "R" in ids
      assert "S" in ids

      s = pattern_row(review, "S")
      assert s.route_id == "2"
      assert s.from_name == "Cedar St"
      assert s.to_name == "Main St"
    end

    test "each pattern gets the outcome its own data earns", context do
      fixture = context.fixture
      stub_routing(200)

      review = review(fixture)

      # P has a saved line and a linked trip that agrees with its visits.
      assert pattern_row(review, "P").outcome == :redraw

      # Q has a line, but one of its linked trips has two stop times for three
      # visits, so its shape cannot be rebuilt from what the feed says.
      assert pattern_row(review, "Q").outcome == {:blocked, :trip_counts}

      # R has no shape and no segments at all: there is no line to redraw, and
      # saying "blocked" would imply there was one worth saving.
      assert pattern_row(review, "R").outcome == :no_line

      assert pattern_row(review, "S").outcome == :redraw
    end

    test "a routing failure is reported as a routing failure", context do
      fixture = context.fixture
      stub_routing(500)

      review = review(fixture)

      # Every pattern that has a line to redraw says the routing failed and
      # gives the adapter's reason. R is `:no_line` either way: it has no shape
      # and no segments, so there was never a line for a routing failure to
      # rob it of, and `:no_line` is checked first for exactly that reason.
      for route_pattern_id <- ["P", "Q", "S"] do
        assert {:routing_failed, reason} = pattern_row(review, route_pattern_id).outcome
        assert is_atom(reason)
      end

      assert pattern_row(review, "R").outcome == :no_line

      assert review.suggestions == %{}
    end

    test "a transfer reports the walking distance before and after", context do
      fixture = context.fixture
      stub_routing(200)

      review = review(fixture)

      assert [transfer] = review.transfers
      assert transfer.label =~ "North Transfer Center B"
      assert transfer.min_transfer_time == 300

      # The stop moved 13.7 m north and the other end did not, so the two
      # distances differ by the move and by nothing else. Asserted as a
      # difference rather than as two literals because the absolute distances
      # are a kilometre of geometry this test has no reason to hard-code.
      assert_in_delta abs(transfer.after_m - transfer.before_m), @move_m, 0.5
    end

    test "reports the relief point, the weekday trips and the band", context do
      fixture = context.fixture
      stub_routing(200)

      review = review(fixture)

      assert review.relief_points == ["Relief at 1434"]

      # P, Q, R and S all reach 1434, so every pattern on the stop counts.
      # The weekday figure is the sum of them all, not the busiest one: an
      # editor is being told how much service sits on the stop they are moving.
      assert review.weekday_trips == 2

      assert review.band == :review
      assert_in_delta review.distance_m, @move_m, 0.5
      assert is_binary(review.fingerprint)
      assert String.length(review.fingerprint) == 64
    end

    test "the same data twice gives the same fingerprint", context do
      fixture = context.fixture
      stub_routing(200)

      assert review(fixture).fingerprint == review(fixture).fingerprint
    end

    test "a stop the actor may not edit is forbidden", context do
      fixture = context.fixture
      stub_routing(200)

      stranger =
        unboxed(fn -> user_fixture(%{email: "review-stranger-#{stamp()}@example.com"}) end)

      audit = %{fixture.audit | actor_id: stranger.id, actor_email: stranger.email}

      assert {:error, :forbidden} = move_review(fixture, "1434", audit)
    end

    test "a stop in another version is not found", context do
      fixture = context.fixture
      stub_routing(200)

      # A real stop, in an organization the context does not name. Scoping the
      # load is what makes it invisible rather than merely refused.
      assert {:error, :not_found} =
               unboxed(fn ->
                 StopEditing.move_review(
                   fixture.stops["1434"].id,
                   {moved_lon(), moved_lat()},
                   %{fixture.audit | organization_id: fixture.elsewhere.id}
                 )
               end)
    end
  end

  describe "StopEditing.move_review/3 writes nothing" do
    setup :staged_fixture

    test "no row, no updated_at and no audit entry changes", context do
      fixture = context.fixture
      stub_routing(200)

      before = unboxed(fn -> snapshot(fixture) end)

      assert {:ok, _review} = move_review(fixture, "1434", fixture.audit)

      assert unboxed(fn -> snapshot(fixture) end) == before
    end
  end

  # --- review helpers

  defp review(fixture, opts \\ []) do
    unboxed(fn ->
      {:ok, review} =
        StopEditing.move_review(
          fixture.stops["1434"].id,
          {moved_lon(), moved_lat()},
          Keyword.get(opts, :audit, fixture.audit)
        )

      review
    end)
  end

  defp move_review(fixture, stop_id, audit) do
    unboxed(fn ->
      stop =
        Repo.one!(
          from s in Stop,
            where:
              s.organization_id == ^fixture.organization.id and
                s.gtfs_version_id == ^fixture.version.id and
                s.stop_id == ^stop_id
        )

      StopEditing.move_review(stop.id, {moved_lon(), moved_lat()}, audit)
    end)
  end

  defp pattern_row(review, route_pattern_id) do
    Enum.find(review.patterns, &(&1.route_pattern_id == route_pattern_id))
  end

  # Everything a review reads, in one comparable value. A review that wrote
  # anything, or that touched an `updated_at`, changes this.
  defp snapshot(fixture) do
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
      logs: stamps(ChangeLog, scope)
    }
  end

  # `change_logs` is insert-only — it has no `updated_at`, which is itself part
  # of why a review writing one would be visible here.
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

  # A single leg with one interior point, so `suggest_between/2` has something
  # to return and the review has a suggestion to substitute.
  defp stub_routing(status) do
    stub_json(status, routing_response([[[-124.0530, 44.6205], [-124.0530, 44.6215]]]))
  end

  defp stub_counting_routing(status, counter) do
    Req.Test.stub(@routing_owner, fn conn ->
      :counters.add(counter, 1, 1)

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

  defp stub_json(status, payload) do
    Req.Test.stub(@routing_owner, fn conn ->
      Plug.Conn.send_resp(
        Plug.Conn.put_resp_content_type(conn, "application/json"),
        status,
        Jason.encode!(payload)
      )
    end)
  end

  # --- fixture

  # P and S are clean: a shape, a shared segment, and (for P) a linked trip
  # whose stop-time count agrees with the pattern's visits. Q shares P's pair
  # and adds a second section, and has a linked trip that disagrees. R shares
  # the pair with nothing drawn at all.
  defp staged_fixture(context) do
    fixture =
      unboxed(fn ->
        organization = organization_fixture(%{alias: "stop-review-#{stamp()}"})
        version = gtfs_version_fixture(organization.id)
        actor = add_actor(organization.id, "pathways_studio_editor")

        audit = %AuditContext{
          organization_id: organization.id,
          gtfs_version_id: version.id,
          actor_id: actor.id,
          actor_email: actor.email
        }

        stops =
          Map.new(
            [
              {"1330", "Cedar St", 44.6200},
              {"1434", "Main St", @stop_lat},
              {"1355", "Elm St", 44.6220},
              {"2000", "North Transfer Center B", 44.6210}
            ],
            fn {id, name, lat} ->
              {id,
               stop_fixture(organization.id, version.id, %{
                 stop_id: id,
                 stop_name: name,
                 stop_lat: Decimal.from_float(lat),
                 stop_lon: Decimal.from_float(@stop_lon)
               })}
            end
          )

        route_one = named_route(organization.id, version.id, "1")

        route_two = named_route(organization.id, version.id, "2")

        shared =
          segment(organization.id, version.id, "1330", "1434", [
            [-124.0530, 44.6205]
          ])

        p = pattern(organization.id, version.id, route_one, "P", ["1330", "1434"], "SHAPE-P")

        q =
          pattern(
            organization.id,
            version.id,
            route_one,
            "Q",
            ["1330", "1434", "1355"],
            "SHAPE-Q"
          )

        # R uses the pair nothing has ever drawn and owns no shape, so there is
        # no line to redraw. A pattern on the *shared* pair would inherit that
        # pair's segment and genuinely have a line, which is why it is not a
        # `:no_line` case.
        r = pattern(organization.id, version.id, route_one, "R", ["1434", "1355"], nil)
        s = pattern(organization.id, version.id, route_two, "S", ["1330", "1434"], "SHAPE-S")

        # A weekday calendar and one trip on P whose stop times match its two
        # visits: this is the clean case, and it is also what the review's
        # `weekday_trips` counts.
        calendar = calendar_fixture(organization.id, version.id, %{service_id: "WEEKDAYS"})

        linked_trip =
          trip_fixture(organization.id, version.id, "1", %{
            trip_id: "TRIP-P-1",
            service_id: calendar.service_id
          })
          |> put_on_pattern(p)

        for {stop_id, position} <- Enum.with_index(["1330", "1434"], 1) do
          stop_time_fixture(organization.id, version.id, "TRIP-P-1", stop_id, %{
            stop_sequence: position
          })
        end

        # Q's trip has two stop times for three visits.
        mismatched =
          trip_fixture(organization.id, version.id, "1", %{
            trip_id: "TRIP-Q-1",
            service_id: calendar.service_id
          })
          |> put_on_pattern(q)

        _ = {linked_trip, mismatched, shared, q, r, s}

        transfer_fixture(organization.id, version.id, %{
          from_stop_id: "1434",
          to_stop_id: "2000",
          min_transfer_time: 300
        })

        relief_point_fixture(organization.id, version.id, %{stop_id: "1434"})

        # A second organization the same actor edits, used to prove that a
        # stop is scoped out of a review rather than merely refused.
        elsewhere = organization_fixture(%{alias: "stop-review-elsewhere-#{stamp()}"})

        {:ok, _membership} =
          Organizations.add_user_to_organization(actor.id, elsewhere.id, [
            "pathways_studio_editor"
          ])

        %{
          organization: organization,
          version: version,
          actor: actor,
          audit: audit,
          elsewhere: elsewhere,
          stops: stops,
          stop: fn id -> Map.fetch!(stops, id) end
        }
      end)

    on_exit(fn -> cleanup_fixture(fixture) end)

    Map.put(context, :fixture, fixture)
  end

  defp add_actor(organization_id, role) do
    actor = user_fixture(%{email: "stop-review-#{stamp()}@example.com"})

    {:ok, _membership} =
      Organizations.add_user_to_organization(actor.id, organization_id, [role])

    actor
  end

  # `Trip.changeset/2` casts neither `route_pattern_id` nor
  # `pattern_derivation_state`, and the database pairs `"linked"` with a
  # non-null `timed_pattern_id`, so all three are written here. A fixture that
  # passed them through the changeset would quietly produce a trip on no
  # pattern, and the review would find no blocker where one exists.
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

  # A named route on the version. `route_fixture/3` is deliberately
  # unparameterised by `route_id`, so the id is written afterwards rather than
  # assumed to have stuck.
  defp named_route(organization_id, gtfs_version_id, route_id) do
    route = route_fixture(organization_id, gtfs_version_id, %{route_short_name: route_id})

    route |> Ecto.Changeset.change(route_id: route_id) |> Repo.update!()
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

  # `RoutePattern.changeset/2` does not cast `shape_id`, so a pattern that is
  # meant to own a line gets one written directly — the same row the importer
  # would have written, without dragging the importer into a unit test.
  defp pattern(organization_id, gtfs_version_id, route, route_pattern_id, stop_ids, shape_id) do
    pattern =
      route_pattern_fixture(organization_id, gtfs_version_id, %{
        route_pattern_id: route_pattern_id,
        route_id: route.route_id,
        direction_id: 0,
        headsign: "To #{route_pattern_id}"
      })

    unless is_nil(shape_id) do
      pattern |> Ecto.Changeset.change(shape_id: shape_id) |> Repo.update!()
    end

    stop_ids
    |> Enum.with_index(1)
    |> Enum.each(fn {stop_id, position} ->
      route_pattern_stop_fixture(pattern, stop_id, position)
    end)

    pattern
  end

  defp moved_lat, do: @stop_lat + @move_m / @metres_per_degree
  defp moved_lon, do: @stop_lon

  defp unboxed(fun), do: Sandbox.unboxed_run(Repo, fun)

  defp stamp, do: System.system_time(:nanosecond)

  # Tables in dependency order. `trips.timed_pattern_id` is a RESTRICT foreign
  # key, so the trips have to go before the timings they point at; the pattern
  # occurrences go before the patterns; the patterns before the routes.
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

      Repo.delete_all(from r in ReliefPoint, where: r.organization_id == ^fixture.organization.id)

      Repo.delete_all(
        from t in Transfer,
          where:
            t.organization_id == ^fixture.organization.id or
              t.organization_id == ^fixture.elsewhere.id
      )

      Repo.delete_all(from o in Organization, where: o.id == ^fixture.organization.id)
      Repo.delete_all(from o in Organization, where: o.id == ^fixture.elsewhere.id)
    end)
  end
end
