defmodule GtfsPlanner.Gtfs.RoutePatterns.GroupingApplyTest do
  @moduledoc """
  Applying a confirmed grouping review links the reviewed trips and nothing else.

  The fixture is the North Coast Transit scenario from the trip-grouping
  prototype: 24 direction-less supplement trips over two stop orders (18 over
  the route's full 13-stop order, which the route's own pattern already serves,
  and 6 over its first seven stops), plus 2 out-of-order trips and one
  station-only trip derivation refuses. Every expected value is a literal from
  that scenario, the GTFS reference, the MBTA `route_patterns` docs and the
  spec's rules; no production function computes one.

  Each case runs through `ReviewedApplyTransaction.Repo` on an unboxed sandbox
  connection, because that adapter owns a real SERIALIZABLE transaction and
  `SET TRANSACTION ISOLATION LEVEL` cannot run inside the sandbox's outer
  transaction. The fixtures are therefore created inside the same unboxed block
  and removed in `on_exit`, and the adapter configured for the rest of the suite
  is restored in `on_exit`.
  """

  use ExUnit.Case, async: false

  import Ecto.Query
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias Ecto.Adapters.SQL.Sandbox
  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.AuditContext
  alias GtfsPlanner.Gtfs.CalendarAttribute
  alias GtfsPlanner.Gtfs.ChangeLog
  alias GtfsPlanner.Gtfs.ReviewedApplyTransaction
  alias GtfsPlanner.Gtfs.Route
  alias GtfsPlanner.Gtfs.RoutePattern
  alias GtfsPlanner.Gtfs.RoutePatterns.Derivation
  alias GtfsPlanner.Gtfs.RoutePatternStop
  alias GtfsPlanner.Gtfs.Stop
  alias GtfsPlanner.Gtfs.StopTime
  alias GtfsPlanner.Gtfs.TimedPattern
  alias GtfsPlanner.Gtfs.TimedPatternStop
  alias GtfsPlanner.Gtfs.Trip
  alias GtfsPlanner.Organizations.Organization
  alias GtfsPlanner.Repo
  alias GtfsPlanner.Versions.GtfsVersion

  @line_lon -124.0
  @line_lat 44.0
  @line_step 0.001

  setup do
    # The production adapter owns the reviewed serializable boundary; the
    # read-committed test adapter in `config/test.exs` is restored afterwards.
    previous = Application.fetch_env(:gtfs_planner, :reviewed_apply_transaction)

    Application.put_env(
      :gtfs_planner,
      :reviewed_apply_transaction,
      ReviewedApplyTransaction.Repo
    )

    on_exit(fn ->
      case previous do
        {:ok, adapter} -> Application.put_env(:gtfs_planner, :reviewed_apply_transaction, adapter)
        :error -> Application.delete_env(:gtfs_planner, :reviewed_apply_transaction)
      end

      Sandbox.mode(Repo, :manual)
    end)

    # The unboxed connection checks out its own connection, so the suite's
    # shared sandbox mode is released for the duration of these cases.
    Sandbox.mode(Repo, :manual)

    :ok
  end

  test "a confirmed group links its trips to the chosen pattern, names the timing, and leaves stop_times alone" do
    unboxed(fn ->
      scope = build_scenario()
      review = open_review(scope, "1")
      group = group_of(review, 18)
      before = stop_times(scope.organization_id)

      assert {:ok, summary} =
               apply_review(scope, "1", review.fingerprint, [
                 %{key: group.key, direction_id: 0, target: scope.pattern.id}
               ])

      assert summary.trips_linked == 18
      assert summary.patterns_created == 0

      linked = linked_trips(scope.pattern.route_pattern_id, scope.organization_id)
      assert length(linked) == 18
      assert Enum.all?(linked, &(&1.direction_id == 0))

      # Rule 6: the preview named the timing after its one service, and the apply
      # creates it under that name instead of a second naming answer.
      assert [%{name: "Summer weekday supplement"}] = timings(scope.pattern.id)

      # Rule 3 / INV-2: grouping writes linkage, never stop times.
      assert stop_times(scope.organization_id) == before

      # PM-2: the group's own pattern was joined, so no duplicate was created
      # and nothing is left pending for a later build to pick up.
      assert patterns_except(scope.organization_id, "pattern_1_full") == []
      assert Derivation.pending_trip_count(scope.organization_id, scope.version_id, "1") == 0

      # The trips the review did not confirm keep their own classification.
      assert length(custom_trips(scope.organization_id)) == 9

      # Rule 7: linking bumps `updated_at`, so this review is now stale.
      assert Enum.all?(linked, &(NaiveDateTime.compare(&1.updated_at, review.opened_at) == :gt))
    end)
  end

  test "the route audit entry records each linked trip's prior direction" do
    unboxed(fn ->
      scope = build_scenario()
      review = open_review(scope, "1")
      group = group_of(review, 18)

      assert {:ok, _summary} =
               apply_review(scope, "1", review.fingerprint, [
                 %{key: group.key, direction_id: 0, target: scope.pattern.id}
               ])

      route =
        Repo.one!(
          from(r in Route,
            where: r.organization_id == ^scope.organization_id and r.route_id == "1"
          )
        )

      [log] =
        Repo.all(
          from(log in ChangeLog,
            where: log.entity_type == "route_pattern_build" and log.entity_id == ^route.id
          )
        )

      grouped = log.changed_fields["grouped_trips"]

      assert length(grouped) == 18
      assert Enum.all?(grouped, &(&1["prior_direction_id"] == nil))

      assert grouped |> Enum.map(& &1["trip_id"]) |> Enum.sort() ==
               linked_trips(scope.pattern.route_pattern_id, scope.organization_id)
               |> Enum.map(& &1.id)
               |> Enum.sort()
    end)
  end

  test "a group confirmed onto a new pattern creates exactly that one pattern" do
    unboxed(fn ->
      scope = build_scenario()
      review = open_review(scope, "1")
      group = group_of(review, 6)

      assert {:ok, summary} =
               apply_review(scope, "1", review.fingerprint, [
                 %{key: group.key, direction_id: 0, target: :new}
               ])

      assert summary.patterns_created == 1
      assert summary.trips_linked == 6

      # The short order's seven stops become the new pattern's own occurrences.
      [created] = patterns_except(scope.organization_id, "pattern_1_full")
      assert length(occurrences(created.id)) == 7
      assert created.direction_id == 0
      assert length(custom_trips(scope.organization_id)) == 21
    end)
  end

  test "a second apply carrying the first fingerprint is stale and writes nothing" do
    unboxed(fn ->
      scope = build_scenario()
      review = open_review(scope, "1")
      group = group_of(review, 18)

      assert {:ok, _summary} =
               apply_review(scope, "1", review.fingerprint, [
                 %{key: group.key, direction_id: 0, target: scope.pattern.id}
               ])

      before = snapshot(scope.organization_id)

      assert {:error, :stale} =
               apply_review(scope, "1", review.fingerprint, [
                 %{key: group.key, direction_id: 0, target: scope.pattern.id}
               ])

      assert snapshot(scope.organization_id) == before
    end)
  end

  test "a group with no confirmed direction is refused and writes nothing" do
    unboxed(fn ->
      scope = build_scenario()
      review = open_review(scope, "1")
      group = group_of(review, 18)
      before = snapshot(scope.organization_id)

      assert {:error, :invalid_selection} =
               apply_review(scope, "1", review.fingerprint, [%{key: group.key, target: :new}])

      assert snapshot(scope.organization_id) == before
    end)
  end

  test "a target that is another route's pattern is refused and writes nothing" do
    unboxed(fn ->
      scope = build_scenario()
      review = open_review(scope, "1")
      group = group_of(review, 18)

      foreign = insert_foreign_pattern(scope)
      before = snapshot(scope.organization_id)

      assert {:error, :invalid_selection} =
               apply_review(scope, "1", review.fingerprint, [
                 %{key: group.key, direction_id: 0, target: foreign.id}
               ])

      assert snapshot(scope.organization_id) == before
    end)
  end

  test "an unknown group key is refused and writes nothing" do
    unboxed(fn ->
      scope = build_scenario()
      review = open_review(scope, "1")
      before = snapshot(scope.organization_id)

      assert {:error, :invalid_selection} =
               apply_review(scope, "1", review.fingerprint, [
                 %{key: "no-such-group", direction_id: 0, target: :new}
               ])

      assert snapshot(scope.organization_id) == before
    end)
  end

  test "a route of another organization is not found" do
    unboxed(fn ->
      scope = build_scenario()
      review = open_review(scope, "1")
      group = group_of(review, 18)

      other = organization_fixture(%{alias: "other-#{Ecto.UUID.generate()}"})
      other_version = gtfs_version_fixture(other.id)

      audit = %{scope.audit | organization_id: other.id, gtfs_version_id: other_version.id}

      on_exit(fn -> cleanup_organization(other.id) end)

      assert Gtfs.group_left_out_trips(
               "1",
               %{
                 selections: [%{key: group.key, direction_id: 0, target: :new}],
                 fingerprint: review.fingerprint
               },
               audit
             ) == {:error, :not_found}
    end)
  end

  test "a version that is not published is not found" do
    unboxed(fn ->
      scope = build_scenario()
      review = open_review(scope, "1")
      group = group_of(review, 18)

      # `staging` is the lifecycle's own non-published state; `published_at` must
      # clear with it, which the migration's paired check requires.
      Repo.update_all(from(v in GtfsVersion, where: v.id == ^scope.version_id),
        set: [publication_status: "staging", published_at: nil]
      )

      assert {:error, :not_found} =
               apply_review(scope, "1", review.fingerprint, [
                 %{key: group.key, direction_id: 0, target: :new}
               ])
    end)
  end

  # --- helpers ---------------------------------------------------------------

  defp unboxed(fun) do
    result = Sandbox.unboxed_run(Repo, fun)
    :ok
    result
  end

  defp apply_review(scope, route_id, fingerprint, selections) do
    Gtfs.group_left_out_trips(
      route_id,
      %{selections: selections, fingerprint: fingerprint},
      scope.audit
    )
  end

  # The review is opened through the production composition, so the fingerprint
  # the apply is handed is the one the editor's own screen would hold.
  defp open_review(scope, route_id) do
    {:ok, review} = Gtfs.preview_left_out(route_id, scope.audit)

    Map.put(review, :opened_at, DateTime.utc_now() |> DateTime.truncate(:microsecond))
  end

  defp group_of(review, trip_count), do: Enum.find(review.groups, &(&1.trip_count == trip_count))

  # Everything a refused or stale apply must leave untouched.
  defp snapshot(organization_id) do
    route =
      Repo.one!(
        from(r in Route, where: r.organization_id == ^organization_id and r.route_id == "1")
      )

    %{
      patterns:
        Repo.aggregate(
          from(p in RoutePattern, where: p.organization_id == ^organization_id),
          :count
        ),
      occurrences:
        Repo.aggregate(
          from(o in RoutePatternStop, where: o.organization_id == ^organization_id),
          :count
        ),
      timings:
        Repo.aggregate(
          from(t in TimedPattern, where: t.organization_id == ^organization_id),
          :count
        ),
      timing_rows:
        Repo.aggregate(
          from(r in TimedPatternStop,
            where:
              r.timed_pattern_id in subquery(
                from(t in TimedPattern,
                  where: t.organization_id == ^organization_id,
                  select: t.id
                )
              )
          ),
          :count
        ),
      stop_times:
        Repo.aggregate(from(s in StopTime, where: s.organization_id == ^organization_id), :count),
      trips:
        Repo.all(
          from(t in Trip,
            where: t.organization_id == ^organization_id,
            order_by: [asc: t.trip_id],
            select:
              {t.trip_id, t.pattern_derivation_state, t.route_pattern_id, t.direction_id,
               t.updated_at}
          )
        ),
      pending: Derivation.pending_trip_count(route.organization_id, route.gtfs_version_id, "1"),
      audits:
        Repo.aggregate(from(l in ChangeLog, where: l.organization_id == ^organization_id), :count)
    }
  end

  defp stop_times(organization_id) do
    Repo.all(
      from(st in StopTime,
        where: st.organization_id == ^organization_id,
        order_by: [asc: st.trip_id, asc: st.stop_sequence],
        select: {st.trip_id, st.stop_id, st.stop_sequence, st.arrival_time, st.departure_time}
      )
    )
  end

  defp linked_trips(route_pattern_id, organization_id) do
    Repo.all(
      from(t in Trip,
        where:
          t.organization_id == ^organization_id and t.route_pattern_id == ^route_pattern_id and
            t.pattern_derivation_state == "linked",
        order_by: [asc: t.trip_id]
      )
    )
  end

  defp custom_trips(organization_id) do
    Repo.all(
      from(t in Trip,
        where: t.organization_id == ^organization_id and t.pattern_derivation_state == "custom",
        select: t.id
      )
    )
  end

  defp patterns_except(organization_id, route_pattern_id) do
    Repo.all(
      from(p in RoutePattern,
        where: p.organization_id == ^organization_id and p.route_pattern_id != ^route_pattern_id
      )
    )
  end

  defp occurrences(pattern_id),
    do:
      Repo.all(
        from(o in RoutePatternStop, where: o.route_pattern_id == ^pattern_id, select: o.id)
      )

  defp timings(pattern_id),
    do: Repo.all(from(t in TimedPattern, where: t.route_pattern_id == ^pattern_id, select: t))

  # --- fixture ---------------------------------------------------------------

  # The North Coast Transit supplement: 18 trips over the route's full order and
  # 6 over its first seven stops, both with no direction, plus the two trips
  # derivation refuses for chronology and the one it refuses for a station stop.
  defp build_scenario do
    organization =
      organization_fixture(%{alias: "grouping-apply-#{Ecto.UUID.generate()}"})

    version = gtfs_version_fixture(organization.id)
    org_id = organization.id
    version_id = version.id

    on_exit(fn -> cleanup_organization(org_id) end)

    route_fixture(org_id, version_id, %{route_id: "1"})

    stop_ids = insert_line_stops(org_id, version_id)
    station_id = insert_station(org_id, version_id)

    pattern = insert_pattern(org_id, version_id, "1", stop_ids)

    for {service_id, description} <- [
          {"SU1", "Summer weekday supplement"},
          {"SU2", "Weekend connector"}
        ] do
      calendar_attribute_fixture(org_id, version_id, %{
        service_id: service_id,
        service_description: description
      })
    end

    insert_supplement(org_id, version_id, stop_ids, "full", stop_ids, 18, "SU1", 0)
    insert_supplement(org_id, version_id, stop_ids, "short", Enum.take(stop_ids, 7), 6, "SU2", 1)
    insert_out_of_order(org_id, version_id, stop_ids, 2)
    insert_station_trip(org_id, version_id, station_id)

    %{
      organization_id: org_id,
      version_id: version_id,
      pattern: pattern,
      stop_ids: stop_ids,
      audit: %AuditContext{
        organization_id: org_id,
        gtfs_version_id: version_id,
        actor_id: Ecto.UUID.generate(),
        actor_email: "editor@example.com"
      }
    }
  end

  defp insert_line_stops(org_id, version_id) do
    for index <- 0..12 do
      stop_fixture(org_id, version_id, %{
        stop_id: "stop_line_#{index}",
        stop_name: "Line Stop #{index}",
        stop_lat: @line_lat + index * @line_step,
        stop_lon: @line_lon
      }).stop_id
    end
  end

  defp insert_station(org_id, version_id) do
    stop_fixture(org_id, version_id, %{
      stop_id: "station_only",
      stop_name: "Depoe Bay Station",
      location_type: 1,
      stop_lat: @line_lat,
      stop_lon: @line_lon
    }).stop_id
  end

  defp insert_pattern(org_id, version_id, route_id, stop_ids) do
    pattern =
      route_pattern_fixture(org_id, version_id, %{
        route_pattern_id: "pattern_#{route_id}_full",
        route_id: route_id,
        direction_id: 0,
        route_pattern_name: "Newport Transit Center – Lincoln City",
        derivation_key: "d0-#{route_id}",
        representative_trip_id: nil
      })

    stop_ids
    |> Enum.with_index(1)
    |> Enum.each(fn {stop_id, position} ->
      route_pattern_stop_fixture(pattern, stop_id, position)
    end)

    pattern
  end

  # A pattern of a second route, so naming it as a target is a scope question
  # rather than a missing row.
  defp insert_foreign_pattern(scope) do
    other_route = route_fixture(scope.organization_id, scope.version_id, %{route_id: "2"})

    # The scenario's own corridor stops, reused: `insert_line_stops/2` would
    # collide with them on `stops_organization_id_gtfs_version_id_stop_id_index`
    # because the scope is a route, not a whole organization.
    insert_pattern(scope.organization_id, scope.version_id, other_route.route_id, scope.stop_ids)
  end

  defp insert_supplement(org_id, version_id, all_stops, label, stop_ids, count, service, hour) do
    for index <- 1..count do
      trip_id = "supplement_#{label}_#{index}"

      insert_custom_trip(org_id, version_id, trip_id, "1", service, "missing_direction")

      insert_vector(org_id, version_id, trip_id, stop_ids, hour * 60, length(all_stops))
    end
  end

  defp insert_out_of_order(org_id, version_id, stop_ids, count) do
    [first, second | _rest] = stop_ids

    for index <- 1..count do
      trip_id = "out_of_order_#{index}"

      insert_custom_trip(org_id, version_id, trip_id, "1", "SU1", "invalid_chronology")

      insert_vector(org_id, version_id, trip_id, [first, second], 7 * 60, 20,
        times: ["08:05:00", "08:00:00"]
      )
    end
  end

  defp insert_station_trip(org_id, version_id, station_id) do
    trip_id = "station_trip_1"

    insert_custom_trip(org_id, version_id, trip_id, "1", "SU1", "unusable_stops")

    insert_vector(org_id, version_id, trip_id, [station_id], 9 * 60, 30)
  end

  defp insert_custom_trip(org_id, version_id, trip_id, route_id, service_id, reason) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    %Trip{}
    |> Ecto.Changeset.change(%{
      id: Ecto.UUID.generate(),
      trip_id: trip_id,
      route_id: route_id,
      service_id: service_id,
      shape_id: "shape_#{trip_id}",
      direction_id: nil,
      pattern_derivation_state: "custom",
      pattern_derivation_reason: reason,
      organization_id: org_id,
      gtfs_version_id: version_id,
      inserted_at: now,
      updated_at: now
    })
    |> Repo.insert!()
  end

  # One minute per stop from `base`, so a trip's own times are chronological
  # unless the fixture deliberately makes them otherwise. `band` keeps each
  # group's `stop_sequence` values apart, which is what makes two stop orders
  # two groups rather than one merged order.
  defp insert_vector(org_id, version_id, trip_id, stop_ids, base, band, opts \\ []) do
    times = Keyword.get(opts, :times)

    stop_ids
    |> Enum.with_index()
    |> Enum.each(fn {stop_id, index} ->
      time = if times, do: Enum.at(times, index), else: hhmm(base + index)

      stop_time_fixture(org_id, version_id, trip_id, stop_id, %{
        stop_sequence: band * 1000 + index + 1,
        arrival_time: time,
        departure_time: time
      })
    end)
  end

  defp hhmm(minutes) do
    :io_lib.format("~2..0B:~2..0B:00", [div(minutes, 60), rem(minutes, 60)])
    |> to_string()
  end

  # These cases commit through an unboxed connection, so their rows are removed
  # explicitly rather than by the sandbox rollback.
  defp cleanup_organization(organization_id) do
    Sandbox.unboxed_run(Repo, fn ->
      Repo.delete_all(from(l in ChangeLog, where: l.organization_id == ^organization_id))
      Repo.delete_all(from(s in StopTime, where: s.organization_id == ^organization_id))

      Repo.delete_all(
        from(r in TimedPatternStop,
          where:
            r.timed_pattern_id in subquery(
              from(t in TimedPattern, where: t.organization_id == ^organization_id, select: t.id)
            )
        )
      )

      Repo.delete_all(from(t in Trip, where: t.organization_id == ^organization_id))
      Repo.delete_all(from(t in TimedPattern, where: t.organization_id == ^organization_id))
      Repo.delete_all(from(o in RoutePatternStop, where: o.organization_id == ^organization_id))
      Repo.delete_all(from(p in RoutePattern, where: p.organization_id == ^organization_id))
      Repo.delete_all(from(s in Stop, where: s.organization_id == ^organization_id))
      Repo.delete_all(from(r in Route, where: r.organization_id == ^organization_id))
      Repo.delete_all(from(a in CalendarAttribute, where: a.organization_id == ^organization_id))
      Repo.delete_all(from(v in GtfsVersion, where: v.organization_id == ^organization_id))
      Repo.delete_all(from(o in Organization, where: o.id == ^organization_id))
    end)
  end
end
