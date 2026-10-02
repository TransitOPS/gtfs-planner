defmodule GtfsPlanner.Gtfs.Alignments.RedrawStopPairsTest do
  @moduledoc """
  `Alignments.redraw_stop_pairs!/3`.

  Moving a stop changes the street its lines should follow, and this is the
  function that draws them. What is under test is that it is *honest* about
  which lines it could draw: the redrawable pattern gets new shape rows, the
  pattern whose trip disagrees with its visits keeps the bytes it had and is
  reported with the reason it could not be redrawn, and a pattern that shares
  no pair with the moved stop is not touched at all.

  The last case is the one the rest would pass without: the segments carry an
  optimistic `lock_version`, and a segment another editor moved on between
  the review and the redraw has to roll the whole thing back rather than
  overwrite them.

  The function runs in the caller's transaction, so every case here drives it
  through `Repo.transaction/1` with a real move written first — the anchors
  the segments resolve against are the stop rows, not the review's snapshot.
  """

  use ExUnit.Case, async: false

  import Ecto.Query
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias Ecto.Adapters.SQL.Sandbox
  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Accounts.User
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
  alias GtfsPlanner.Gtfs.StopTime
  alias GtfsPlanner.Gtfs.TimedPattern
  alias GtfsPlanner.Gtfs.Trip
  alias GtfsPlanner.Organizations.Organization
  alias GtfsPlanner.Repo

  @stop_lat 44.6210
  @stop_lon -124.0530
  @move_m 13.7
  @metres_per_degree 111_320.0

  # The routing double's one interior point. Asserted as a literal rather than
  # read back from the code under test, so a change to the suggestion
  # contract fails here instead of quietly agreeing with itself.
  @suggested [[-124.0530, 44.6205], [-124.0525, 44.6208]]

  setup do
    fixture = staged_fixture()

    on_exit(fn -> cleanup_fixture(fixture) end)

    {:ok, fixture: fixture}
  end

  describe "redraw_stop_pairs!/3 segment writes" do
    test "the shared segment takes the suggested points and a new lock_version", context do
      fixture = context.fixture

      before = segment(fixture, "1330", "1434")

      result = move_and_redraw(fixture)

      assert result.segments_written == 1

      segment = segment(fixture, "1330", "1434")

      assert segment.points == @suggested
      # The optimistic lock is what makes a second redraw of the same segment
      # a conflict rather than a silent overwrite, so it has to move. Asserted
      # as a difference because the insert's starting value is the column
      # default's business, not this function's.
      assert segment.lock_version == before.lock_version + 1
    end

    test "a pair with no segment yet gets a shared one", context do
      fixture = context.fixture

      # Scoped to this version: the shared partition holds other versions'
      # segments, and "no segment for this pair" has to mean *this* version's.
      assert unboxed(fn ->
               Repo.exists?(
                 from(s in AlignmentSegment,
                   where:
                     s.organization_id == ^fixture.organization.id and
                       s.gtfs_version_id == ^fixture.version.id and
                       s.to_stop_id == "1360"
                 )
               )
             end) == false

      result =
        unboxed(fn ->
          Repo.transaction(fn ->
            move_stop(fixture)

            Alignments.redraw_stop_pairs!(
              fixture.organization.id,
              fixture.version.id,
              %{
                suggestions: %{{"1355", "1360"} => @suggested},
                audit_context: fixture.audit
              }
            )
          end)
        end)

      assert {:ok, %{segments_written: 1}} = result

      created = segment(fixture, "1355", "1360")

      assert created.points == @suggested
      assert is_nil(created.from_occurrence_id)
    end

    test "the write is audited as an alignment_segment update", context do
      fixture = context.fixture

      before = change_log_count(fixture)

      move_and_redraw(fixture)

      assert change_log_count(fixture) > before

      entry =
        unboxed(fn ->
          Repo.one(
            from(log in ChangeLog,
              where:
                log.organization_id == ^fixture.organization.id and
                  log.gtfs_version_id == ^fixture.version.id and
                  log.entity_type == "alignment_segment",
              order_by: [desc: log.inserted_at],
              limit: 1,
              select: log
            )
          )
        end)

      assert entry.action == "updated"
    end
  end

  describe "redraw_stop_pairs!/3 pattern outcomes" do
    test "a redrawable pattern is rematerialized and reports :current", context do
      fixture = context.fixture

      result = move_and_redraw(fixture)

      assert [%{route_pattern_id: "P"}, %{route_pattern_id: "S"}] = result.redrawn

      p = pattern(fixture, "P")

      assert unboxed(fn -> Alignments.resolve(p).status.export end) == :current

      # Two visits and one interior leg: the two stops are the anchors and
      # the routed points sit between them. A redraw that dropped the moved
      # stop's new position would leave the line pointing at where the stop
      # used to be, which is the whole failure this function exists to prevent.
      points = shape_points(fixture, "SHAPE-P")

      assert length(points) == 4
      assert hd(points) == [-124.0530, 44.6200]
      assert Enum.slice(points, 1, 2) == @suggested

      # `stop_lat`/`stop_lon` are `numeric(9, 6)`, so the stored anchor is the
      # move rounded to the column's resolution — about 11 cm. That is the
      # column's tolerance, not the assertion's, and it is far finer than the
      # 13.7 m move being detected.
      [last_lon, last_lat] = List.last(points)
      assert_in_delta last_lon, -124.0530, 0.000_001
      assert_in_delta last_lat, moved_lat(), 0.000_001
    end

    test "a pattern blocked by trip counts keeps its rows and is reported", context do
      fixture = context.fixture

      before = shape_points(fixture, "SHAPE-Q")

      result = move_and_redraw(fixture)

      # P and S on the same pair redraw; Q on that pair does not. Q's rows
      # and digest have to survive the redraw its neighbours performed.
      assert ["P", "S"] == Enum.map(result.redrawn, & &1.route_pattern_id)
      assert [%{route_pattern_id: "Q", reason: {:blocked, :trip_counts}}] = result.stale

      assert shape_points(fixture, "SHAPE-Q") == before

      q = pattern(fixture, "Q")

      assert unboxed(fn -> Alignments.resolve(q).status.export end) == :stale
    end

    test "a pattern with no line at all is left out of both lists", context do
      fixture = context.fixture

      result = move_and_redraw(fixture)

      ids = Enum.map(result.redrawn ++ result.stale, & &1.route_pattern_id)

      # R shares the pair but owns no shape and has no segment, so there was
      # never a line to redraw. Listing it as stale would tell the editor
      # their drag cost a line it never had.
      refute "R" in ids
    end

    test "a pattern on another route sharing the pair is redrawn too", context do
      fixture = context.fixture

      result = move_and_redraw(fixture)

      assert ["P", "S"] == Enum.map(result.redrawn, & &1.route_pattern_id)
    end

    test "a pattern on an unrelated pair is untouched", context do
      fixture = context.fixture

      before = {
        segment(fixture, "1500", "1501").points,
        shape_points(fixture, "SHAPE-T"),
        pattern(fixture, "T").alignment_digest
      }

      result = move_and_redraw(fixture)

      ids = Enum.map(result.redrawn ++ result.stale, & &1.route_pattern_id)

      refute "T" in ids

      # Compared after the redraw rather than captured up front, so the
      # assertion cannot pass by both sides being read at the same moment.
      assert {
               segment(fixture, "1500", "1501").points,
               shape_points(fixture, "SHAPE-T"),
               pattern(fixture, "T").alignment_digest
             } == before
    end

    test "a failed pair is reported as a routing failure, not a data problem", context do
      fixture = context.fixture

      result =
        unboxed(fn ->
          Repo.transaction(fn ->
            move_stop(fixture)

            Alignments.redraw_stop_pairs!(
              fixture.organization.id,
              fixture.version.id,
              %{
                suggestions: %{},
                failed: %{{"1330", "1434"} => :unavailable},
                audit_context: fixture.audit
              }
            )
          end)
        end)

      assert {:ok, %{redrawn: [], stale: stale}} = result

      # P and S share the pair, so both are told the routing failed. Q shares
      # it too and is reported the same way rather than as a data problem:
      # the reason the line cannot be redrawn is that nobody answered.
      assert [
               %{route_pattern_id: "P", reason: {:routing_failed, :unavailable}},
               %{route_pattern_id: "Q", reason: {:routing_failed, :unavailable}},
               %{route_pattern_id: "S", reason: {:routing_failed, :unavailable}}
             ] = stale
    end
  end

  describe "redraw_stop_pairs!/3 refuses a moved segment" do
    test "a lock_version bumped after the review rolls back with :stale_review", context do
      fixture = context.fixture

      # The value the review would have recorded before anybody saved.
      current = segment(fixture, "1330", "1434").lock_version
      reviewed = %{{"1330", "1434", nil} => current}

      outcome =
        unboxed(fn ->
          Repo.transaction(fn ->
            move_stop(fixture)

            # Somebody else saved this segment between the review and here.
            # The read is written out rather than reusing the `segment/4`
            # helper: that helper checks a connection out of the sandbox, and
            # this is already inside a transaction that owns it.
            Repo.update_all(
              from(s in AlignmentSegment,
                where:
                  s.organization_id == ^fixture.organization.id and
                    s.gtfs_version_id == ^fixture.version.id and
                    s.from_stop_id == "1330" and
                    s.to_stop_id == "1434"
              ),
              set: [points: [[-124.06, 44.63]], lock_version: current + 1]
            )

            Alignments.redraw_stop_pairs!(
              fixture.organization.id,
              fixture.version.id,
              %{
                suggestions: %{{"1330", "1434"} => @suggested},
                reviewed_lock_versions: reviewed,
                audit_context: fixture.audit
              }
            )
          end)
        end)

      assert {:error, :stale_review} == outcome

      # The rollback is the point: the other editor's geometry and the stop's
      # new coordinates are both still there.
      assert unboxed(fn -> segment(fixture, "1330", "1434").points end) == [[-124.06, 44.63]]
      assert unboxed(fn -> stop_lat(fixture) end) == 44.6210
    end
  end

  # --- drivers

  # The stop move happens first, in the same transaction, because that is the
  # order `apply_move/4` uses and because the segments resolve against the stop
  # rows.
  defp move_and_redraw(fixture) do
    {:ok, result} =
      unboxed(fn ->
        Repo.transaction(fn ->
          move_stop(fixture)

          Alignments.redraw_stop_pairs!(
            fixture.organization.id,
            fixture.version.id,
            %{suggestions: %{{"1330", "1434"} => @suggested}, audit_context: fixture.audit}
          )
        end)
      end)

    result
  end

  defp move_stop(fixture) do
    lat = Decimal.from_float(moved_lat())
    now = DateTime.utc_now()

    {count, _} =
      Repo.update_all(
        from(s in Stop,
          where:
            s.organization_id == ^fixture.organization.id and s.id == ^fixture.stops["1434"].id
        ),
        set: [stop_lat: lat, updated_at: now]
      )

    count
  end

  defp segment(fixture, from_id, to_id) do
    unboxed(fn ->
      Repo.one!(
        from(s in AlignmentSegment,
          where:
            s.organization_id == ^fixture.organization.id and
              s.gtfs_version_id == ^fixture.version.id and
              s.from_stop_id == ^from_id and
              s.to_stop_id == ^to_id
        )
      )
    end)
  end

  defp pattern(fixture, route_pattern_id) do
    unboxed(fn ->
      Repo.one!(
        from(p in RoutePattern,
          where:
            p.organization_id == ^fixture.organization.id and
              p.gtfs_version_id == ^fixture.version.id and
              p.route_pattern_id == ^route_pattern_id
        )
      )
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

  defp change_log_count(fixture) do
    unboxed(fn ->
      Repo.one(
        from(log in ChangeLog,
          where:
            log.organization_id == ^fixture.organization.id and
              log.gtfs_version_id == ^fixture.version.id,
          select: count(log.id)
        )
      )
    end)
  end

  defp stop_lat(fixture) do
    unboxed(fn ->
      Repo.one!(from(s in Stop, where: s.id == ^fixture.stops["1434"].id, select: s.stop_lat))
      |> Decimal.to_float()
    end)
  end

  defp moved_lat, do: @stop_lat + @move_m / @metres_per_degree

  defp unboxed(fun), do: Sandbox.unboxed_run(Repo, fun)

  defp stamp, do: System.system_time(:nanosecond)

  # --- fixture

  # P and S share (1330,1434) on two different routes and both have a linked
  # trip that agrees with their visits. Q shares the pair and adds a second
  # section, and its linked trip has two stop times for three visits. R shares
  # the pair with nothing drawn at all. T is on a pair of its own.
  defp staged_fixture do
    unboxed(fn ->
      organization = organization_fixture(%{alias: "redraw-#{stamp()}"})
      version = gtfs_version_fixture(organization.id)
      actor = add_actor(organization.id)

      audit = %AuditContext{
        organization_id: organization.id,
        gtfs_version_id: version.id,
        actor_id: actor.id,
        actor_email: actor.email
      }

      stops = seed_stops(organization.id, version.id)

      route_one = named_route(organization.id, version.id, "1")
      route_two = named_route(organization.id, version.id, "2")

      # The saved geometry, deliberately not equal to the suggestion, so a
      # redraw that wrote nothing would be visible.
      for {from_id, to_id, points} <- [
            {"1330", "1434", [[-124.06, 44.63]]},
            {"1434", "1355", [[-124.04, 44.63]]},
            {"1500", "1501", [[-124.07, 44.61]]}
          ] do
        segment(organization.id, version.id, from_id, to_id, points)
      end

      p = pattern(organization.id, version.id, route_one, "P", ["1330", "1434"], "SHAPE-P")

      q =
        pattern(organization.id, version.id, route_one, "Q", ["1330", "1434", "1355"], "SHAPE-Q")

      r = pattern(organization.id, version.id, route_one, "R", ["1330", "1434"], nil)
      s = pattern(organization.id, version.id, route_two, "S", ["1330", "1434"], "SHAPE-S")
      t = pattern(organization.id, version.id, route_two, "T", ["1500", "1501"], "SHAPE-T")

      calendar = calendar_fixture(organization.id, version.id, %{service_id: "WEEKDAYS"})

      for {pattern_row, trip_id, stop_ids} <- [
            {p, "TRIP-P-1", ["1330", "1434"]},
            {s, "TRIP-S-1", ["1330", "1434"]},
            {t, "TRIP-T-1", ["1500", "1501"]}
          ] do
        seed_trip(
          organization.id,
          version.id,
          pattern_row,
          trip_id,
          stop_ids,
          calendar.service_id
        )
      end

      # Q's trip disagrees with Q's visits: two stop times for three visits.
      seed_trip(organization.id, version.id, q, "TRIP-Q-1", ["1330", "1434"], calendar.service_id)

      _ = {q, r}

      for shape_id <- ["SHAPE-P", "SHAPE-Q", "SHAPE-S", "SHAPE-T"] do
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
        {"1355", "Elm St", 44.6220},
        {"1360", "Birch St", 44.6240},
        {"1500", "Harbour Way", 44.6100},
        {"1501", "Quay St", 44.6110}
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
    actor = user_fixture(%{email: "redraw-#{stamp()}@example.com"})

    {:ok, _membership} =
      Accounts.create_user_org_membership(%{
        user_id: actor.id,
        organization_id: organization_id,
        roles: ["pathways_studio_editor"]
      })

    actor
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

  # `RoutePattern.changeset/2` does not cast `shape_id`, so a pattern meant
  # to own a line gets one written directly.
  defp pattern(organization_id, gtfs_version_id, route, route_pattern_id, stop_ids, shape_id) do
    pattern =
      route_pattern_fixture(organization_id, gtfs_version_id, %{
        route_pattern_id: route_pattern_id,
        route_id: route.route_id,
        direction_id: 0,
        headsign: "To #{route_pattern_id}"
      })

    pattern =
      case shape_id do
        nil ->
          pattern

        _owned ->
          pattern |> Ecto.Changeset.change(shape_id: shape_id) |> Repo.update!()
      end

    stop_ids
    |> Enum.with_index(1)
    |> Enum.each(fn {stop_id, position} ->
      route_pattern_stop_fixture(pattern, stop_id, position)
    end)

    pattern
  end

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

      # An unboxed test commits the user its actor fixture created. Deleting the
      # organization removes the membership but not the user, and a leftover
      # user breaks the first-administrator tests, which need a database with no
      # committed users.
      Repo.delete_all(from u in User, where: like(u.email, "redraw-%"))
    end)
  end
end
