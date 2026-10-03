defmodule GtfsPlanner.Gtfs.RoutePatterns.DerivationLabelsTest do
  @moduledoc """
  Derivation of supplied route-pattern labels: trips that reference supplied
  pattern `1-0-A` and serve a different stop order join a child pattern labelled
  by that owner instead of staying custom `different_stops`, so the exported
  `route_pattern_id` stays the supplied ID for all of them (rule 1 of the
  proposal, AC-19).

  The shape is the prototype scenario — 40 all-stop trips on the owner and 4
  express trips on the child, 44 linked trips — written as a small
  `route_patterns.txt` feed and run through the real import, which is the
  production path that calls `Derivation.derive_version/3`.

  Every expected value is a literal from the MBTA `route_patterns.txt`
  documentation, the GTFS `route_pattern_id` reference, the prototype scenario
  and the spec rules. No production function computes an expected value here;
  the stop lists, counts, reasons and key shapes are all authored below.
  """

  use GtfsPlanner.DataCase, async: false

  import Ecto.Query
  import GtfsPlanner.GtfsFixtures, only: [stored_occurrences: 1]
  import GtfsPlanner.OrganizationsFixtures

  alias GtfsPlanner.Gtfs.Import.{Run, Runner}
  alias GtfsPlanner.Gtfs.ImportRuns
  alias GtfsPlanner.Gtfs.RoutePattern
  alias GtfsPlanner.Gtfs.RoutePatterns.Derivation
  alias GtfsPlanner.Gtfs.TimedPattern
  alias GtfsPlanner.Gtfs.Trip

  alias GtfsPlanner.Repo
  alias GtfsPlanner.Support.StagedImport
  alias GtfsPlanner.TaskSupervisor

  alias Ecto.Adapters.SQL.Sandbox

  @label "1-0-A"
  @route_id "Red"

  # Nine stops, served in full by the all-stop trips.
  @all_stop_ids ~w(S1 S2 S3 S4 S5 S6 S7 S8 S9)

  # The express trips skip the four interior stops between them.
  @express_stop_ids ~w(S1 S3 S5 S7 S9)

  @owner_trip_count 40
  @express_trip_count 4

  setup do
    organization =
      organization_fixture(%{
        alias: "derivation-labels-#{System.system_time(:nanosecond)}"
      })

    actor = editor_fixture(organization)

    %{organization: organization, actor: actor}
  end

  test "express trips join a child pattern labelled by the supplied pattern", context do
    version_id = import_feed(context)

    owner = pattern(context, version_id, @label)
    assert is_nil(owner.label_pattern_id)
    assert owner.direction_id == 0
    assert stop_list(owner) == @all_stop_ids

    assert [child] = children(context, version_id, owner)
    assert child.label_pattern_id == owner.route_pattern_id
    assert child.direction_id == owner.direction_id
    assert stop_list(child) == @express_stop_ids

    # One owner and one child, and no supplied trip left outside a pattern for
    # having a different stop order.
    assert patterns(context, version_id) |> length() == 2
    assert linked_trip_count(context, version_id) == @owner_trip_count + @express_trip_count
    assert custom_reasons(context, version_id) == []

    # The express trips really did move onto the child's own natural ID.
    for index <- 1..@express_trip_count do
      trip = Repo.get_by!(Trip, trip_id: express_trip_id(index), gtfs_version_id: version_id)
      assert trip.pattern_derivation_state == "linked"
      assert trip.route_pattern_id == child.route_pattern_id
      refute trip.route_pattern_id == @label
    end
  end

  test "a supplied trip in the other direction stays a custom scope mismatch", context do
    version_id =
      import_feed(context,
        extra_trips: [
          %{trip_id: "T-other-direction", direction_id: 1, stop_ids: @all_stop_ids}
        ]
      )

    owner = pattern(context, version_id, @label)

    assert [child] = children(context, version_id, owner)
    assert child.direction_id == owner.direction_id
    assert child.direction_id == 0

    other = Repo.get_by!(Trip, trip_id: "T-other-direction", gtfs_version_id: version_id)
    assert other.pattern_derivation_state == "custom"
    assert other.pattern_derivation_reason == "scope_mismatch"
    assert is_nil(other.timed_pattern_id)
    # A trip that joined no pattern keeps its supplied reference verbatim.
    assert other.route_pattern_id == @label
  end

  test "re-running derivation reuses the same child and creates nothing new", context do
    version_id = import_feed(context)

    owner = pattern(context, version_id, @label)
    [child] = children(context, version_id, owner)
    timings_before = timings(context, version_id) |> length()
    assert timings_before == 2

    reset_pending(context, version_id)

    assert {:ok, summary} =
             Derivation.derive_route(
               context.organization.id,
               version_id,
               @route_id,
               {:import, nil}
             )

    assert summary.patterns_created == 0
    assert summary.timings_created == 0
    assert summary.trips_linked == @owner_trip_count + @express_trip_count

    assert [same_child] = children(context, version_id, owner)
    assert same_child.id == child.id
    assert patterns(context, version_id) |> length() == 2
    assert timings(context, version_id) |> length() == timings_before
    assert linked_trip_count(context, version_id) == @owner_trip_count + @express_trip_count
    assert custom_reasons(context, version_id) == []
  end

  test "a child's derivation key names its owner, direction and stop list", context do
    version_id = import_feed(context)

    owner = pattern(context, version_id, @label)
    [child] = children(context, version_id, owner)

    assert String.starts_with?(child.derivation_key, "l-" <> @label <> "-")

    assert child.derivation_key ==
             "l-" <> @label <> "-d0-" <> stop_list_hash(@express_stop_ids)

    # The key is a function of the owner, the direction and the stop list only,
    # so a different stop list or a different owner cannot produce this one.
    refute child.derivation_key ==
             "l-" <> @label <> "-d0-" <> stop_list_hash(@all_stop_ids)

    refute child.derivation_key ==
             "l-1-0-B-d0-" <> stop_list_hash(@express_stop_ids)
  end

  # --- import ---------------------------------------------------------------

  # A feed whose only supplied pattern is `1-0-A`, carrying forty all-stop trips
  # and four express trips that all reference it. The route pattern row follows
  # the MBTA `route_patterns.txt` columns, and its representative trip is one of
  # the all-stop trips, so the owner's canonical sequence is the full stop list.
  defp import_feed(context, opts \\ []) do
    extra_trips = Keyword.get(opts, :extra_trips, [])

    {:ok, %{run: run}} =
      ImportRuns.create_pending_target(
        context.organization.id,
        %{id: context.actor.id, email: context.actor.email},
        %{name: "Derivation Labels Feed"}
      )

    {:ok, runner_pid} =
      Runner.start_import(
        context.organization.id,
        run.id,
        run.lease_token,
        files: StagedImport.stage(feed(extra_trips))
      )

    Sandbox.allow(Repo, self(), runner_pid)
    await_runner(runner_pid)

    assert Repo.get!(Run, run.id).state == "published"

    version_id = run.gtfs_version_id
    counts = Repo.get!(Run, run.id).committed_counts
    assert counts["route_patterns"] == 1
    assert counts["patterns_created"] == 1
    assert counts["trips_linked"] == @owner_trip_count + @express_trip_count
    assert counts["trips_custom"] == length(extra_trips)

    version_id
  end

  defp feed(extra_trips) do
    trips =
      all_stop_trips() ++ express_trips() ++ Enum.map(extra_trips, &Map.put_new(&1, :start, 30))

    [
      %{filename: "routes.txt", content: routes_csv()},
      %{filename: "stops.txt", content: stops_csv()},
      %{filename: "trips.txt", content: trips_csv(trips)},
      %{filename: "stop_times.txt", content: stop_times_csv(trips)},
      %{filename: "route_patterns.txt", content: route_patterns_csv()}
    ]
  end

  defp routes_csv do
    """
    route_id,route_type,route_short_name,route_long_name
    #{@route_id},3,1,Red Line
    """
  end

  defp stops_csv do
    header = "stop_id,stop_name,stop_lat,stop_lon,location_type,wheelchair_boarding\n"

    rows =
      @all_stop_ids
      |> Enum.with_index()
      |> Enum.map_join("\n", fn {stop_id, index} ->
        "#{stop_id},#{stop_id} #{index},#{40.0 + index / 100},-75.0,0,0"
      end)

    header <> rows <> "\n"
  end

  defp route_patterns_csv do
    """
    route_pattern_id,route_id,direction_id,route_pattern_name,route_pattern_time_desc,route_pattern_typicality,route_pattern_sort_order,representative_trip_id,canonical_route_pattern
    #{@label},#{@route_id},0,Alewife – Ashmont,All day,1,1,#{all_stop_trip_id(1)},0
    """
  end

  defp all_stop_trip_id(index), do: "T-all-" <> pad(index)

  defp express_trip_id(index), do: "T-express-" <> pad(index)

  defp pad(index), do: index |> Integer.to_string() |> String.pad_leading(2, "0")

  defp all_stop_trips do
    for index <- 1..@owner_trip_count do
      %{trip_id: all_stop_trip_id(index), direction_id: 0, stop_ids: @all_stop_ids, start: index}
    end
  end

  defp express_trips do
    for index <- 1..@express_trip_count do
      %{
        trip_id: express_trip_id(index),
        direction_id: 0,
        stop_ids: @express_stop_ids,
        start: 20 + index
      }
    end
  end

  defp trips_csv(trips) do
    header = "trip_id,route_id,service_id,direction_id,trip_headsign,route_pattern_id\n"

    rows =
      Enum.map_join(trips, "\n", fn trip ->
        "#{trip.trip_id},#{@route_id},WK,#{trip.direction_id},Alewife,#{@label}"
      end)

    header <> rows <> "\n"
  end

  defp stop_times_csv(trips) do
    header = "trip_id,stop_id,stop_sequence,arrival_time,departure_time\n"

    rows =
      trips
      |> Enum.flat_map(fn trip ->
        trip.stop_ids
        |> Enum.with_index(0)
        |> Enum.map(fn {stop_id, stops_passed} ->
          time = clock(trip.start + stops_passed * 2)

          "#{trip.trip_id},#{stop_id},#{stops_passed + 1},#{time},#{time}"
        end)
      end)
      |> Enum.join("\n")

    header <> rows <> "\n"
  end

  defp clock(minutes), do: "08:" <> pad(minutes) <> ":00"

  defp await_runner(runner_pid) do
    for pid <- Task.Supervisor.children(TaskSupervisor) do
      Sandbox.allow(Repo, self(), pid)
      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 30_000
    end

    runner_ref = Process.monitor(runner_pid)
    assert_receive {:DOWN, ^runner_ref, :process, ^runner_pid, _reason}, 30_000
  end

  # --- queries --------------------------------------------------------------

  defp patterns(context, version_id) do
    from(p in RoutePattern,
      where: p.organization_id == ^context.organization.id and p.gtfs_version_id == ^version_id,
      order_by: [asc: p.route_pattern_id]
    )
    |> Repo.all()
  end

  defp pattern(context, version_id, natural_id) do
    Repo.get_by!(RoutePattern,
      organization_id: context.organization.id,
      gtfs_version_id: version_id,
      route_pattern_id: natural_id
    )
  end

  defp children(context, version_id, owner) do
    from(p in RoutePattern,
      where:
        p.organization_id == ^context.organization.id and p.gtfs_version_id == ^version_id and
          p.label_pattern_id == ^owner.route_pattern_id,
      order_by: [asc: p.route_pattern_id]
    )
    |> Repo.all()
  end

  defp stop_list(pattern) do
    pattern.id |> stored_occurrences() |> Enum.map(& &1.stop_id)
  end

  defp stop_list_hash(stop_ids) do
    stop_ids
    |> Enum.join(<<0>>)
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
    |> String.slice(0, 32)
  end

  defp linked_trip_count(context, version_id) do
    from(t in Trip,
      where:
        t.organization_id == ^context.organization.id and t.gtfs_version_id == ^version_id and
          t.pattern_derivation_state == "linked",
      select: count(t.id)
    )
    |> Repo.one()
  end

  defp custom_reasons(context, version_id) do
    from(t in Trip,
      where:
        t.organization_id == ^context.organization.id and t.gtfs_version_id == ^version_id and
          t.pattern_derivation_state == "custom",
      select: t.pattern_derivation_reason,
      order_by: [asc: t.trip_id]
    )
    |> Repo.all()
  end

  defp timings(context, version_id) do
    from(t in TimedPattern,
      where: t.organization_id == ^context.organization.id and t.gtfs_version_id == ^version_id
    )
    |> Repo.all()
  end

  # Replays the state the first derivation actually saw: every trip back on the
  # supplied reference it was imported with and pending again. The express trips
  # now carry the child's generated natural ID, so resetting only the trips that
  # still name the owner would never reach the child a second time.
  defp reset_pending(context, version_id) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    label = @label

    from(t in Trip,
      where: t.organization_id == ^context.organization.id and t.gtfs_version_id == ^version_id
    )
    |> Repo.update_all(
      set: [
        route_pattern_id: label,
        pattern_derivation_state: "pending",
        pattern_derivation_reason: nil,
        timed_pattern_id: nil,
        updated_at: now
      ]
    )
  end
end
