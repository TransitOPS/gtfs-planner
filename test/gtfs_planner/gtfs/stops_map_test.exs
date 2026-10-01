defmodule GtfsPlanner.Gtfs.StopsMapTest do
  @moduledoc """
  `StopsMap.load/2` is the Map view's only database read, and it is a read model
  whose cost an editor feels directly. Three properties are checked here.

  The query count does not grow with the pattern count. A read model that grows a
  query per pattern is indistinguishable, to a user, from a broken map on a real
  feed, so one pattern and fifty patterns must cost the same. Both counts are
  measured here through a `[:gtfs_planner, :repo, :query]` handler.

  Lines come from saved geometry in this order: the pattern's own shape,
  else the most common shape among its linked trips, else a straight connector
  through its located stops. A wrong order draws the wrong road.

  Nothing crosses a version or organization boundary. A stop, a shape or a trip
  of another version naming the same natural IDs must be absent, or two feeds
  side by side in the seed would draw each other's stops.
  """

  use GtfsPlanner.DataCase, async: false

  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Gtfs.Shape
  alias GtfsPlanner.Gtfs.StopsMap
  alias GtfsPlanner.Repo

  setup do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)

    %{organization: organization, version: version}
  end

  describe "served?" do
    test "a stop only stop_times name is served", %{organization: org, version: version} do
      route = route_fixture(org.id, version.id, %{route_id: "R1"})
      trip = trip_fixture(org.id, version.id, route.route_id, %{route_id: route.route_id})

      _stop = stop_fixture(org.id, version.id, %{stop_id: "S1", stop_name: "Main St"})
      stop_time_fixture(org.id, version.id, trip.trip_id, "S1")

      model = load!(org, version)

      assert served?(model, "S1")
    end

    test "a stop no row names is not served", %{organization: org, version: version} do
      stop_fixture(org.id, version.id, %{stop_id: "S9", stop_name: "Lonely"})

      model = load!(org, version)

      refute served?(model, "S9")
    end

    test "a stop only a pattern visits is served", %{organization: org, version: version} do
      route = route_fixture(org.id, version.id, %{route_id: "R1"})
      other = stop_fixture(org.id, version.id, %{stop_id: "S0", stop_name: "First"})
      stop = stop_fixture(org.id, version.id, %{stop_id: "S1", stop_name: "Second"})
      pattern = route_pattern_fixture(org.id, version.id, %{route_id: route.route_id})

      route_pattern_stop_fixture(pattern, other.stop_id, 1)
      route_pattern_stop_fixture(pattern, stop.stop_id, 2)

      assert served?(load!(org, version), "S1")
    end
  end

  describe "line sources" do
    test "a pattern with its own shape uses the shape rows", %{
      organization: org,
      version: version
    } do
      pattern = build_pattern(org, version, "shape-own")
      stops = build_stops(org, version, ["S1", "S2"])
      route_pattern_stop_fixture(pattern, stops["S1"].stop_id, 1)
      route_pattern_stop_fixture(pattern, stops["S2"].stop_id, 2)

      shape_points!(org, version, "shape-own", [{-124.05, 44.62}, {-124.06, 44.63}])

      line = line(load!(org, version), pattern.id)

      assert line.source == :shape
      assert rounded(line.points) == [[-124.05, 44.62], [-124.06, 44.63]]
    end

    test "a pattern without its own shape uses its most common linked-trip shape", %{
      organization: org,
      version: version
    } do
      route = route_fixture(org.id, version.id, %{route_id: "R1"})

      pattern =
        route_pattern_fixture(org.id, version.id, %{route_id: route.route_id, shape_id: nil})

      # Two trips on "shape-major", one on "shape-minor": the majority wins.
      # `Trip.changeset/2` casts no `route_pattern_id` — the pattern-linking
      # path writes it — so the fixture sets it explicitly.
      for index <- 1..2 do
        linked_trip(org, version, route.route_id, "T#{index}", pattern, "shape-major")
      end

      linked_trip(org, version, route.route_id, "T3", pattern, "shape-minor")

      shape_points!(org, version, "shape-major", [{-124.10, 44.70}])
      shape_points!(org, version, "shape-minor", [{-124.90, 44.90}])

      line = line(load!(org, version), pattern.id)

      assert line.source == :shape
      assert rounded(line.points) == [[-124.1, 44.7]]
    end

    test "a pattern with neither gets a connector through its located stops", %{
      organization: org,
      version: version
    } do
      pattern = build_pattern(org, version, nil)
      stops = build_stops(org, version, ["S1", "S2"])
      route_pattern_stop_fixture(pattern, stops["S1"].stop_id, 1)
      route_pattern_stop_fixture(pattern, stops["S2"].stop_id, 2)

      line = line(load!(org, version), pattern.id)

      assert line.source == :connector
      assert rounded(line.points) == [[-124.05, 44.62], [-124.05, 44.63]]
    end

    test "a connector skips an unlocated stop rather than inventing a point", %{
      organization: org,
      version: version
    } do
      pattern = build_pattern(org, version, nil)

      first =
        stop_fixture(org.id, version.id, %{
          stop_id: "S1",
          stop_lat: Decimal.new("44.62"),
          stop_lon: Decimal.new("-124.05")
        })

      middle =
        stop_fixture(org.id, version.id, %{stop_id: "S2", stop_lat: nil, stop_lon: nil})

      last =
        stop_fixture(org.id, version.id, %{
          stop_id: "S3",
          stop_lat: Decimal.new("44.64"),
          stop_lon: Decimal.new("-124.05")
        })

      route_pattern_stop_fixture(pattern, first.stop_id, 1)
      route_pattern_stop_fixture(pattern, middle.stop_id, 2)
      route_pattern_stop_fixture(pattern, last.stop_id, 3)

      line = line(load!(org, version), pattern.id)

      assert rounded(line.points) == [[-124.05, 44.62], [-124.05, 44.64]]
    end
  end

  describe "query count" do
    test "one pattern and fifty patterns cost the same", %{organization: org, version: version} do
      # The fixture runs before the handler is attached, so only the loads are
      # counted: the property is about the read, not about building the data.
      build_patterns(org, version, 1, "one")
      one_pattern = count_queries(fn -> load!(org, version) end)

      many = build_patterns(org, version, 50, "many")
      fifty_patterns = count_queries(fn -> load!(org, version) end)

      assert one_pattern == fifty_patterns
      assert length(load!(org, version).lines) == 51
      assert length(many) == 50
    end
  end

  describe "version and organization scope" do
    test "a row of another version is absent", %{organization: org, version: version} do
      other_version = gtfs_version_fixture(org.id)

      pattern = build_pattern(org, version, "shape-x")
      stop_fixture(org.id, version.id, %{stop_id: "S1", stop_name: "Ours"})

      # Same natural IDs, different version: a shape and a stop that must not
      # appear in this version's model.
      stop_fixture(org.id, other_version.id, %{stop_id: "S2", stop_name: "Theirs"})
      shape_points!(org, other_version, "shape-x", [{10.0, 10.0}])

      model = load!(org, version)

      assert Enum.map(model.stops, & &1.stop_id) == ["S1"]
      assert line(model, pattern.id).points == []
    end
  end

  describe "routes and bounds" do
    test "the route carries the names and colours the hook draws with", %{
      organization: org,
      version: version
    } do
      route =
        route_fixture(org.id, version.id, %{
          route_id: "R#{System.unique_integer([:positive])}",
          route_short_name: "12",
          route_long_name: "Coast",
          route_color: "1F6FB2",
          route_text_color: "FFFFFF"
        })

      build_pattern(org, version, nil, route)

      route_row = load!(org, version).routes[route.route_id]

      assert route_row.short_name == "12"
      assert route_row.long_name == "Coast"
      assert route_row.color == "1F6FB2"
      assert route_row.text_color == "FFFFFF"
    end

    test "bounds are the corner pair of located stops", %{organization: org, version: version} do
      stop_fixture(org.id, version.id, %{
        stop_id: "S1",
        stop_lat: Decimal.new("44.0"),
        stop_lon: Decimal.new("-125.0")
      })

      stop_fixture(org.id, version.id, %{
        stop_id: "S2",
        stop_lat: Decimal.new("45.0"),
        stop_lon: Decimal.new("-124.0")
      })

      assert load!(org, version).bounds == {{-125.0, 44.0}, {-124.0, 45.0}}
    end

    test "a version with no located stop has no bounds", %{organization: org, version: version} do
      stop_fixture(org.id, version.id, %{stop_id: "S1", stop_lat: nil, stop_lon: nil})

      assert load!(org, version).bounds == nil
    end
  end

  describe "display_payload/2" do
    test "keeps the first and last point of every line", %{organization: org, version: version} do
      _pattern = build_pattern(org, version, "shape-1")

      # A straight run east with dense collinear filler, then a right-angle
      # turn and more filler. The filler sits about 1 m off the straight, under
      # the 2 m tolerance, so it is noise; the corner is 22 m off, so it is the
      # shape. Exactly three points must survive: start, corner, end. If the
      # simplifier kept the filler the payload would be the whole shape, and if
      # it dropped an endpoint the drawn route would stop short of the corner.
      shape_points!(org, version, "shape-1", [
        {-124.05000, 44.60000},
        {-124.04999, 44.60000},
        {-124.04998, 44.60000},
        {-124.04900, 44.60000},
        {-124.04900, 44.60001},
        {-124.04900, 44.60002},
        {-124.04899, 44.60002}
      ])

      model = load!(org, version)
      payload = StopsMap.display_payload(model, 2.0)

      points = payload.lines |> hd() |> Map.fetch!(:points)

      assert length(model.lines |> hd() |> Map.fetch!(:points)) == 7
      # Fewer points than the shape had: the filler is gone. Not "exactly
      # three" — a two-point slice short-circuits, so a sliver of near-collinear
      # filler either side of the corner can survive within tolerance. The
      # property simplification owes the map is the endpoints and the corner.
      assert length(points) < 7
      assert rounded(points) |> List.first() == [-124.05, 44.6]
      assert rounded(points) |> List.last() == [-124.04899, 44.60002]
      # The corner is the point that carries the shape, and it survives.
      assert Enum.any?(points, fn [_lon, lat] -> lat > 44.6000 end)
    end

    test "a straight shape collapses to its two endpoints", %{organization: org, version: version} do
      _pattern = build_pattern(org, version, "shape-straight")

      shape_points!(org, version, "shape-straight", [
        {-124.05000, 44.60000},
        {-124.04999, 44.60000},
        {-124.04998, 44.60000},
        {-124.04997, 44.60000},
        {-124.04996, 44.60000}
      ])

      points =
        load!(org, version)
        |> StopsMap.display_payload(2.0)
        |> Map.fetch!(:lines)
        |> hd()
        |> Map.fetch!(:points)

      assert length(points) == 2
      assert rounded(points) == [[-124.05, 44.6], [-124.04996, 44.6]]
    end

    test "returns lon-lat numbers, not tuples", %{organization: org, version: version} do
      stop_fixture(org.id, version.id, %{
        stop_id: "S1",
        stop_lat: Decimal.new("44.62"),
        stop_lon: Decimal.new("-124.05")
      })

      payload = StopsMap.display_payload(load!(org, version), 2.0)

      assert payload.stops |> hd() |> Map.fetch!(:point) == [-124.05, 44.62]
      assert payload.bounds == [[-124.05, 44.62], [-124.05, 44.62]]

      # JSON-safe means JSON-safe: this is the encoding the hook receives.
      assert {:ok, _json} = Jason.encode(payload)
    end

    test "an unlocated stop keeps a nil point rather than a zero", %{
      organization: org,
      version: version
    } do
      stop_fixture(org.id, version.id, %{stop_id: "S1", stop_lat: nil, stop_lon: nil})

      payload = StopsMap.display_payload(load!(org, version), 2.0)

      assert payload.stops |> hd() |> Map.fetch!(:point) == nil
    end

    test "names the served flag the way the hook reads it", %{
      organization: org,
      version: version
    } do
      stop_fixture(org.id, version.id, %{
        stop_id: "S1",
        stop_lat: Decimal.new("44.62"),
        stop_lon: Decimal.new("-124.05")
      })

      [stop] =
        load!(org, version)
        |> StopsMap.display_payload(2.0)
        |> Map.fetch!(:stops)

      # The model asks `served?` because Elixir asks a question. This map is
      # the JSON boundary and the hook reads `stop.served`; carried across
      # unchanged the key arrives as `"served?"`, which is undefined for every
      # stop — so an unserved stop draws as a served one and nothing fails.
      assert Map.fetch!(stop, :served) == false
      assert Jason.encode!(stop) =~ ~s("served":false)
    end
  end

  # --- fixtures and helpers

  defp load!(organization, version) do
    assert {:ok, model} = StopsMap.load(organization.id, version.id)
    model
  end

  defp served?(model, stop_id) do
    model.stops |> Enum.find(&(&1.stop_id == stop_id)) |> Map.fetch!(:served?)
  end

  defp line(model, pattern_id) do
    Enum.find(model.lines, &(&1.pattern_id == pattern_id))
  end

  # A pattern on its own route, or on `route` when one is given, with
  # `shape_id` set when one is passed. `RoutePattern.changeset/2` does not cast
  # `shape_id` — the pattern-linking path writes it — so the fixture sets it
  # explicitly.
  defp build_pattern(organization, version, shape_id, route \\ nil) do
    route =
      route ||
        route_fixture(organization.id, version.id, %{
          route_id: "R#{System.unique_integer([:positive])}"
        })

    organization.id
    |> route_pattern_fixture(version.id, %{
      route_id: route.route_id,
      direction_id: 0,
      headsign: "To Town"
    })
    |> then(fn pattern ->
      pattern
      |> Ecto.Changeset.change(%{shape_id: shape_id})
      |> Repo.update!()
    end)
  end

  # A trip linked to a pattern by its natural ids, which neither changeset casts.
  defp linked_trip(organization, version, route_id, trip_id, pattern, shape_id) do
    trip =
      trip_fixture(organization.id, version.id, route_id, %{trip_id: trip_id, shape_id: shape_id})

    trip
    |> Ecto.Changeset.change(%{
      route_pattern_id: pattern.route_pattern_id,
      shape_id: shape_id
    })
    |> Repo.update!()
  end

  # Coordinates come back from `Decimal.to_float/1`, so a literal 44.63 is
  # 44.629999999999995. Expectations are literals, so they are compared at the
  # precision a person wrote them at. Accepts `{lon, lat}` tuples and
  # `[lon, lat]` pairs alike, because the model uses one and the payload the
  # other and both are asserted here.
  defp rounded(points) when is_list(points) do
    Enum.map(points, fn
      {lon, lat} -> [round(lon * 1_000_000) / 1_000_000, round(lat * 1_000_000) / 1_000_000]
      [lon, lat] -> [round(lon * 1_000_000) / 1_000_000, round(lat * 1_000_000) / 1_000_000]
    end)
  end

  # Builds `count` patterns on one route, each with a linked trip and a shape, so
  # the load has real geometry to assemble at either size.
  defp build_patterns(organization, version, count, prefix) do
    route = route_fixture(organization.id, version.id, %{route_id: "R-#{prefix}"})

    for index <- 1..count do
      pattern =
        organization.id
        |> route_pattern_fixture(version.id, %{route_id: route.route_id})
        |> then(fn pattern ->
          pattern
          |> Ecto.Changeset.change(%{shape_id: "shape-#{prefix}-#{index}"})
          |> Repo.update!()
        end)

      stops =
        build_stops(organization, version, ["#{prefix}-#{index}-A", "#{prefix}-#{index}-B"])

      Enum.each(stops, fn {stop_id, stop} ->
        route_pattern_stop_fixture(pattern, stop.stop_id, :erlang.phash2(stop_id) + 1)
      end)

      shape_points!(organization, version, pattern.shape_id, [
        {-124.05, 44.60 + index / 100},
        {-124.06, 44.61 + index / 100}
      ])

      pattern
    end
  end

  defp build_stops(organization, version, stop_ids) do
    stop_ids
    |> Enum.with_index()
    |> Map.new(fn {stop_id, index} ->
      {stop_id,
       stop_fixture(organization.id, version.id, %{
         stop_id: stop_id,
         stop_name: "Stop #{stop_id}",
         stop_lat: Decimal.new(to_string(44.62 + index * 0.01)),
         stop_lon: Decimal.new("-124.05")
       })}
    end)
  end

  # Shape points as `{lon, lat}`, the order `StopsMap` and `StopPlacement` use.
  defp shape_points!(organization, version, shape_id, points) do
    now = DateTime.utc_now()

    rows =
      Enum.map(points, fn {lon, lat} ->
        %{
          organization_id: organization.id,
          gtfs_version_id: version.id,
          shape_id: shape_id,
          shape_pt_sequence: System.unique_integer([:positive]),
          shape_pt_lat: Decimal.new(to_string(lat)),
          shape_pt_lon: Decimal.new(to_string(lon)),
          inserted_at: now,
          updated_at: now
        }
      end)

    {count, nil} = Repo.insert_all(Shape, rows)
    if count != length(rows), do: raise("insert_all wrote #{count} of #{length(rows)} shape rows")
  end

  # Ecto emits `[:gtfs_planner, :repo, :query]` in the process that issued the
  # query, and the load may later fan out to a Task, so the tally lives in an
  # Agent rather than this test's mailbox.
  defp count_queries(fun) do
    counter = start_supervised!({Agent, fn -> 0 end}, id: {:stops_map_counter, make_ref()})
    handler_id = "stops-map-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler_id,
      [:gtfs_planner, :repo, :query],
      fn _event, _measurements, metadata, counter ->
        if metadata.repo == Repo, do: Agent.update(counter, &(&1 + 1))
      end,
      counter
    )

    try do
      fun.()
      Agent.get(counter, & &1)
    after
      :telemetry.detach(handler_id)
    end
  end
end
