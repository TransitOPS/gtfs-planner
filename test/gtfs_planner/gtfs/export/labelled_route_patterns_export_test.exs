defmodule GtfsPlanner.Gtfs.Export.LabelledRoutePatternsExportTest do
  @moduledoc """
  Merge evidence (EV-16) for rule 9: a labelled route pattern is an editor-only
  construct, so an export writes the owner's `route_pattern_id` on every trip
  that reaches a child, writes the owners alone to `route_patterns.txt`, and
  leaves a feed without labels byte-for-byte unchanged.

  The labelled cases run the prototype scenario through the real import —
  supplied pattern `1-0-A` with 40 all-stop trips and 4 express trips serving a
  different stop order — and then export the published version, which is the
  production path `Export.export_to_zip/3` → `StreamBuilder.stream_records/4`.
  A label removed afterwards is exported as the first-class pattern it has
  become, and the R6 inactive-route closure still wins over the label join.

  Every expected value is a literal from the MBTA `route_patterns.txt`
  documentation, the GTFS `route_pattern_id` reference, the prototype scenario
  and the spec rules, or the golden export bytes captured before this change.
  No production function computes an expected value here.
  """

  use GtfsPlanner.DataCase, async: false

  import Ecto.Query
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias Ecto.Adapters.SQL.Sandbox
  alias GtfsPlanner.Gtfs.AuditContext
  alias GtfsPlanner.Gtfs.Export
  alias GtfsPlanner.Gtfs.Import.Run
  alias GtfsPlanner.Gtfs.Import.Runner
  alias GtfsPlanner.Gtfs.ImportRuns
  alias GtfsPlanner.Gtfs.RoutePattern
  alias GtfsPlanner.Gtfs.RoutePatterns
  alias GtfsPlanner.Support.StagedImport
  alias GtfsPlanner.TaskSupervisor

  @label "1-0-A"
  @route_id "Red"

  @all_stop_ids ~w(S1 S2 S3 S4 S5 S6 S7 S8 S9)
  @express_stop_ids ~w(S1 S3 S5 S7 S9)
  @owner_trip_count 40
  @express_trip_count 4

  # The exported bytes of the unlabelled round-trip fixture, captured from
  # `export_to_zip/3` before the label join existed. They are the whole file,
  # header included, so a changed column or value fails here. Trips sharing a
  # route have no secondary export ordering, so compare their literal rows
  # independently of that unspecified order.
  @golden_trips """
  route_id,service_id,trip_id,trip_headsign,trip_short_name,direction_id,block_id,shape_id,wheelchair_accessible,bikes_allowed,route_pattern_id
  RP_ROUTE,WEEKDAY,RP_TRIP_LINKED,Linked Destination,,1,,,,,RP_B
  RP_ROUTE,WEEKDAY,RP_TRIP_CUSTOM,Custom Destination,,0,,,,,RP_ABSENT_PATTERN
  """

  @golden_route_patterns """
  route_pattern_id,route_id,direction_id,route_pattern_name,route_pattern_time_desc,route_pattern_typicality,route_pattern_sort_order,representative_trip_id,canonical_route_pattern
  RP_A,RP_ROUTE,0,Alpha,Saturday,1,1,,0
  RP_B,RP_ROUTE,1,Beta,Weekday,2,3,RP_TRIP_LINKED,1
  """

  setup do
    organization =
      organization_fixture(%{alias: "labelled-export-#{System.system_time(:nanosecond)}"})

    %{organization: organization, actor: editor_fixture(organization)}
  end

  test "every trip of a labelled pattern exports the owner's ID and the child is not exported",
       context do
    version_id = import_feed(context)
    child = child_pattern(context, version_id)

    files = export!(context.organization.id, version_id)

    # All 44 supplied trips — the 40 on the owner's own stop list and the 4
    # express trips on the child's — leave with `1-0-A`, the supplied ID.
    trip_rows = csv_rows(files, "trips.txt")
    assert length(trip_rows) == @owner_trip_count + @express_trip_count
    assert trip_rows |> Enum.map(&column(&1, "route_pattern_id")) |> Enum.uniq() == [@label]

    # The child is a real row in the database and absent from the export, so no
    # exported trip names a pattern `route_patterns.txt` does not list.
    assert Repo.get!(RoutePattern, child.id).route_pattern_id == child.route_pattern_id

    pattern_rows = csv_rows(files, "route_patterns.txt")
    assert Enum.map(pattern_rows, &column(&1, "route_pattern_id")) == [@label]
    assert column(hd(pattern_rows), "route_id") == @route_id
    assert column(hd(pattern_rows), "direction_id") == "0"
  end

  test "removing the child's label exports the child's own ID and its own row", context do
    version_id = import_feed(context)
    child = child_pattern(context, version_id)

    audit = %AuditContext{
      organization_id: context.organization.id,
      gtfs_version_id: version_id,
      actor_id: context.actor.id,
      actor_email: context.actor.email
    }

    assert {:ok, unlabelled} = RoutePatterns.remove_label(@route_id, child.id, audit)
    assert is_nil(unlabelled.label_pattern_id)

    # The child's natural ID is the editor's own generated identity, so it is
    # read from the row it belongs to rather than guessed; the derivation key
    # beside it is the literal the owner, direction and stop list produce.
    refute child.route_pattern_id == @label

    assert child.derivation_key ==
             "l-" <> @label <> "-d0-" <> stop_list_hash(@express_stop_ids)

    files = export!(context.organization.id, version_id)
    trip_rows = csv_rows(files, "trips.txt")
    by_trip = Map.new(trip_rows, &{column(&1, "trip_id"), &1})

    for index <- 1..@express_trip_count do
      row = Map.fetch!(by_trip, express_trip_id(index))
      assert column(row, "route_pattern_id") == child.route_pattern_id
    end

    for index <- 1..@owner_trip_count do
      row = Map.fetch!(by_trip, all_stop_trip_id(index))
      assert column(row, "route_pattern_id") == @label
    end

    # The unlabelled child is now a first-class pattern, so it gains its row.
    assert files
           |> csv_rows("route_patterns.txt")
           |> Enum.map(&column(&1, "route_pattern_id"))
           |> Enum.sort() ==
             Enum.sort([@label, child.route_pattern_id])
  end

  test "trips of one route export in trip ID order whatever order they were written in",
       context do
    org_id = context.organization.id
    version = gtfs_version_fixture(org_id)
    route_fixture(org_id, version.id, route_id: "R_ORDER")

    for trip_id <- ["T-C", "T-A", "T-B"] do
      trip_fixture(org_id, version.id, "R_ORDER", trip_id: trip_id)
    end

    files = export!(org_id, version.id)

    assert files |> csv_rows("trips.txt") |> Enum.map(&column(&1, "trip_id")) ==
             ["T-A", "T-B", "T-C"]
  end

  test "trips on an inactive route stay excluded while an active route's child exports its owner",
       context do
    org_id = context.organization.id
    version = gtfs_version_fixture(org_id)

    route_fixture(org_id, version.id, route_id: "R_ACTIVE", active: true)
    route_fixture(org_id, version.id, route_id: "R_INACTIVE", active: false)

    for stop_id <- ["S_A", "S_B"] do
      stop_fixture(org_id, version.id, stop_id: stop_id)
    end

    active_owner =
      route_pattern_fixture(org_id, version.id, %{
        route_pattern_id: "P_OWNER",
        route_id: "R_ACTIVE"
      })

    inactive_owner =
      route_pattern_fixture(org_id, version.id, %{
        route_pattern_id: "P_RETIRED",
        route_id: "R_INACTIVE"
      })

    label_child(active_owner, "P_CHILD")
    label_child(inactive_owner, "P_RETIRED_CHILD")

    active = trip_fixture(org_id, version.id, "R_ACTIVE", trip_id: "T_ACTIVE", service_id: "SVC1")
    trip_pattern_metadata_fixture(active, %{route_pattern_id: "P_CHILD"})

    retired =
      trip_fixture(org_id, version.id, "R_INACTIVE", trip_id: "T_RETIRED", service_id: "SVC1")

    trip_pattern_metadata_fixture(retired, %{route_pattern_id: "P_RETIRED_CHILD"})

    for trip_id <- ["T_ACTIVE", "T_RETIRED"] do
      stop_time_fixture(org_id, version.id, trip_id, "S_A",
        stop_sequence: 1,
        arrival_time: "06:00:00",
        departure_time: "06:00:00"
      )

      stop_time_fixture(org_id, version.id, trip_id, "S_B",
        stop_sequence: 2,
        arrival_time: "06:10:00",
        departure_time: "06:10:00"
      )
    end

    files = export!(org_id, version.id)

    trip_rows = csv_rows(files, "trips.txt")
    assert Enum.map(trip_rows, &column(&1, "trip_id")) == ["T_ACTIVE"]
    assert column(hd(trip_rows), "route_pattern_id") == "P_OWNER"

    # The label join must not resurrect the inactive route's closure, and the
    # active route's child is still left out.
    assert files
           |> csv_rows("route_patterns.txt")
           |> Enum.map(&column(&1, "route_pattern_id")) == ["P_OWNER"]
  end

  test "a feed without labels preserves the literal trips rows and route_patterns bytes",
       context do
    org_id = context.organization.id
    version = gtfs_version_fixture(org_id)

    route_fixture(org_id, version.id, route_id: "RP_ROUTE", route_short_name: "RP")
    s1 = stop_fixture(org_id, version.id, stop_id: "RP_S1")
    s2 = stop_fixture(org_id, version.id, stop_id: "RP_S2")

    route_pattern_fixture(org_id, version.id, %{
      route_pattern_id: "RP_A",
      route_id: "RP_ROUTE",
      direction_id: 0,
      route_pattern_name: "Alpha",
      route_pattern_time_desc: "Saturday",
      route_pattern_typicality: 1,
      route_pattern_sort_order: 1,
      representative_trip_id: nil,
      canonical_route_pattern: 0
    })

    pattern_b =
      route_pattern_fixture(org_id, version.id, %{
        route_pattern_id: "RP_B",
        route_id: "RP_ROUTE",
        direction_id: 1,
        route_pattern_name: "Beta",
        route_pattern_time_desc: "Weekday",
        route_pattern_typicality: 2,
        route_pattern_sort_order: 3,
        representative_trip_id: "RP_TRIP_LINKED",
        canonical_route_pattern: 1,
        headsign: "PATTERN_INTERNAL_HEADSIGN",
        derivation_key: "PATTERN_DERIVATION_HASH"
      })

    occ_b1 = route_pattern_stop_fixture(pattern_b, s1.stop_id, 1)
    occ_b2 = route_pattern_stop_fixture(pattern_b, s2.stop_id, 2)

    timing =
      timed_pattern_fixture(pattern_b, %{
        name: "INTERNAL_TIMING_NAME",
        derivation_key: "TIMING_DERIVATION_HASH"
      })

    timed_pattern_stop_fixture(timing, occ_b1, %{arrival_offset: 0, departure_offset: 0})
    timed_pattern_stop_fixture(timing, occ_b2, %{arrival_offset: 300, departure_offset: 300})

    linked =
      trip_fixture(org_id, version.id, "RP_ROUTE",
        trip_id: "RP_TRIP_LINKED",
        service_id: "WEEKDAY",
        direction_id: 1,
        trip_headsign: "Linked Destination"
      )

    trip_pattern_metadata_fixture(linked, %{
      route_pattern_id: "RP_B",
      timed_pattern_id: timing.id,
      pattern_derivation_state: "linked",
      pattern_derivation_reason: nil
    })

    custom =
      trip_fixture(org_id, version.id, "RP_ROUTE",
        trip_id: "RP_TRIP_CUSTOM",
        service_id: "WEEKDAY",
        direction_id: 0,
        trip_headsign: "Custom Destination"
      )

    # A trip naming a pattern that does not exist keeps its stored reference.
    trip_pattern_metadata_fixture(custom, %{
      route_pattern_id: "RP_ABSENT_PATTERN",
      timed_pattern_id: nil,
      pattern_derivation_state: "custom",
      pattern_derivation_reason: "missing_pattern"
    })

    stop_time_fixture(org_id, version.id, "RP_TRIP_LINKED", "RP_S1",
      stop_sequence: 1,
      arrival_time: "06:00:00",
      departure_time: "06:00:00"
    )

    stop_time_fixture(org_id, version.id, "RP_TRIP_LINKED", "RP_S2",
      stop_sequence: 5,
      arrival_time: "06:05:00",
      departure_time: "06:05:00"
    )

    stop_time_fixture(org_id, version.id, "RP_TRIP_CUSTOM", "RP_S1",
      stop_sequence: 1,
      arrival_time: "07:00:00",
      departure_time: "07:00:00"
    )

    files = export!(org_id, version.id)

    [actual_header | actual_rows] = String.split(file_text(files, "trips.txt"), "\n", trim: true)
    [expected_header | expected_rows] = String.split(@golden_trips, "\n", trim: true)
    assert actual_header == expected_header
    assert Enum.sort(actual_rows) == Enum.sort(expected_rows)
    assert file_text(files, "route_patterns.txt") == @golden_route_patterns
  end

  # --- import ---------------------------------------------------------------

  # A feed whose only supplied pattern is `1-0-A`, carrying forty all-stop trips
  # and four express trips that all reference it. Its row follows the MBTA
  # `route_patterns.txt` columns, and its representative trip is one of the
  # all-stop trips, so the owner's canonical sequence is the full stop list.
  defp import_feed(context) do
    {:ok, %{run: run}} =
      ImportRuns.create_pending_target(
        context.organization.id,
        %{id: context.actor.id, email: context.actor.email},
        %{name: "Labelled Export Feed"}
      )

    {:ok, runner_pid} =
      Runner.start_import(context.organization.id, run.id, run.lease_token,
        files: StagedImport.stage(feed())
      )

    Sandbox.allow(Repo, self(), runner_pid)
    await_runner(runner_pid)

    assert Repo.get!(Run, run.id).state == "published"

    version_id = run.gtfs_version_id
    counts = Repo.get!(Run, run.id).committed_counts
    assert counts["route_patterns"] == 1
    assert counts["patterns_created"] == 1
    assert counts["trips_linked"] == @owner_trip_count + @express_trip_count

    version_id
  end

  defp feed do
    trips = all_stop_trips() ++ express_trips()

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

  # --- fixture helpers ------------------------------------------------------

  # The one child derivation creates for the express stop list. Its natural ID
  # is the derivation key, so the label — not a guess — is what identifies it.
  defp child_pattern(context, version_id) do
    [child] =
      Repo.all(
        from(p in RoutePattern,
          where:
            p.organization_id == ^context.organization.id and p.gtfs_version_id == ^version_id and
              not is_nil(p.label_pattern_id),
          select: p
        )
      )

    child
  end

  # `label_pattern_id` is deliberately absent from the cast list, so a fixture
  # sets the pointer directly the way the production label write does.
  defp label_child(owner, natural_id) do
    child =
      route_pattern_fixture(owner.organization_id, owner.gtfs_version_id, %{
        route_pattern_id: natural_id,
        route_id: owner.route_id,
        direction_id: owner.direction_id
      })

    {1, nil} =
      Repo.update_all(
        from(p in RoutePattern, where: p.id == ^child.id),
        set: [label_pattern_id: owner.id, updated_at: DateTime.utc_now()]
      )

    Repo.get!(RoutePattern, child.id)
  end

  defp stop_list_hash(stop_ids) do
    stop_ids
    |> Enum.join(<<0>>)
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
    |> String.slice(0, 32)
  end

  # --- export helpers -------------------------------------------------------

  defp export!(organization_id, version_id) do
    {:ok, zip} = Export.export_to_zip(organization_id, version_id, :full)
    {:ok, entries} = :zip.unzip(zip, [:memory])
    Map.new(entries, fn {name, content} -> {to_string(name), to_string(content)} end)
  end

  defp file_text(files, name) do
    case Map.fetch(files, name) do
      {:ok, text} -> text
      :error -> flunk("expected #{name} in export; got #{inspect(Enum.sort(Map.keys(files)))}")
    end
  end

  # The exported values carry no quoting or embedded separator here, so the
  # header row indexes each column and the data rows are plain splits.
  defp csv_rows(files, name) do
    [header | rows] =
      files
      |> file_text(name)
      |> String.split("\n", trim: true)

    columns = String.split(header, ",")

    Enum.map(rows, fn row ->
      columns |> Enum.zip(String.split(row, ",")) |> Map.new()
    end)
  end

  defp column(row, name) do
    case Map.fetch(row, name) do
      {:ok, value} -> value
      :error -> flunk("no column #{name} in #{inspect(row)}")
    end
  end
end
