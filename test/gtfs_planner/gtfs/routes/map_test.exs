defmodule GtfsPlanner.Gtfs.Routes.MapTest do
  use GtfsPlanner.DataCase

  import Ecto.Query

  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.Shape
  alias GtfsPlanner.Gtfs.Stop
  alias GtfsPlanner.Versions

  setup do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    %{organization: organization, version: version}
  end

  describe "route map through the ordinary public entrypoint" do
    # Scenario 1 through the production composition
    # Gtfs.route_map/3 -> Routes.route_map/3 -> GtfsPlanner.Gtfs.Routes.Map.route_map/3
    # (seam S-3, concrete production adapter: direct call, no test-only wiring).
    test "returns visits, saved connector sections and distinct labelled imported shape variants",
         %{organization: org, version: version} do
      route = route_fixture(org.id, version.id, %{route_id: "r1"})

      pattern_one =
        route_pattern_fixture(org.id, version.id, %{
          route_pattern_id: "p1",
          route_id: "r1",
          direction_id: 0,
          route_pattern_name: "Downtown",
          route_pattern_sort_order: 0
        })

      # A pattern with no trips: it still owns its saved connector sections.
      pattern_two =
        route_pattern_fixture(org.id, version.id, %{
          route_pattern_id: "p2",
          route_id: "r1",
          direction_id: 1,
          route_pattern_name: "Riverside",
          route_pattern_sort_order: 1
        })

      stop_fixture(org.id, version.id, %{
        stop_id: "a",
        stop_lat: Decimal.new("1.0"),
        stop_lon: Decimal.new("2.0")
      })

      stop_fixture(org.id, version.id, %{
        stop_id: "b",
        stop_lat: Decimal.new("1.5"),
        stop_lon: Decimal.new("2.5")
      })

      stop_fixture(org.id, version.id, %{
        stop_id: "c",
        stop_lat: Decimal.new("1.5"),
        stop_lon: Decimal.new("3.0")
      })

      stop_fixture(org.id, version.id, %{
        stop_id: "d",
        stop_lat: Decimal.new("4.0"),
        stop_lon: Decimal.new("5.0")
      })

      stop_fixture(org.id, version.id, %{
        stop_id: "e",
        stop_lat: Decimal.new("4.5"),
        stop_lon: Decimal.new("5.5")
      })

      route_pattern_stop_fixture(pattern_one, "a", 1)
      route_pattern_stop_fixture(pattern_one, "b", 2)
      route_pattern_stop_fixture(pattern_one, "c", 3)
      route_pattern_stop_fixture(pattern_two, "d", 1)
      route_pattern_stop_fixture(pattern_two, "e", 2)

      shape_point_fixture(org, version, "sh1", 1, "1.0", "2.0")
      shape_point_fixture(org, version, "sh1", 2, "1.25", "2.25")
      shape_point_fixture(org, version, "sh2", 1, "3.0", "4.0")
      shape_point_fixture(org, version, "sh2", 2, "3.5", "4.5")

      trip_for_pattern(org, version, "r1", "p1", "sh1")
      trip_for_pattern(org, version, "r1", "p1", "sh2")
      # Duplicate trip copy of the same imported shape: never duplicate geometry.
      trip_for_pattern(org, version, "r1", "p1", "sh1")

      assert {:ok, map} = Gtfs.route_map(org.id, version.id, "r1")

      assert map.route_uuid == route.id
      assert map.route_id == "r1"
      assert map.status == :ok
      assert map.saved_alignment == :unavailable

      # All current-route patterns, in deterministic order.
      assert Enum.map(map.patterns, & &1.route_pattern_id) == ["p1", "p2"]
      [pattern_map_one, pattern_map_two] = map.patterns
      assert pattern_map_one.id == pattern_one.id
      assert pattern_map_one.direction_id == 0
      assert pattern_map_one.route_pattern_name == "Downtown"
      assert pattern_map_two.id == pattern_two.id

      # Ordered occurrence visits with [lon, lat] JSON numbers.
      assert pattern_map_one.visits == [
               %{position: 1, stop_id: "a", coordinates: [2.0, 1.0]},
               %{position: 2, stop_id: "b", coordinates: [2.5, 1.5]},
               %{position: 3, stop_id: "c", coordinates: [3.0, 1.5]}
             ]

      # Connector sections labelled source stop_pair with saved status.
      assert pattern_map_one.sections == [
               %{
                 source: :stop_pair,
                 status: :saved,
                 from_position: 1,
                 to_position: 2,
                 coordinates: [[2.0, 1.0], [2.5, 1.5]]
               },
               %{
                 source: :stop_pair,
                 status: :saved,
                 from_position: 2,
                 to_position: 3,
                 coordinates: [[2.5, 1.5], [3.0, 1.5]]
               }
             ]

      # Owned saved sections survive without any trips on the pattern.
      assert Enum.map(pattern_map_two.sections, &{&1.source, &1.status}) == [
               {:stop_pair, :saved}
             ]

      assert [%{from_position: 1, to_position: 2, coordinates: [[5.0, 4.0], [5.5, 4.5]]}] =
               pattern_map_two.sections

      # Distinct imported shapes remain visible as labelled variants even though
      # three trips reference only two shapes.
      assert map.imported_shape_variants == [
               %{
                 source: :imported_shape,
                 status: :saved,
                 shape_id: "sh1",
                 variant: 1,
                 label: "Variant 1",
                 route_pattern_ids: ["p1"],
                 coordinates: [[2.0, 1.0], [2.25, 1.25]]
               },
               %{
                 source: :imported_shape,
                 status: :saved,
                 shape_id: "sh2",
                 variant: 2,
                 label: "Variant 2",
                 route_pattern_ids: ["p1"],
                 coordinates: [[4.0, 3.0], [4.5, 3.5]]
               }
             ]
    end

    test "missing coordinates omit connectors with unlocated metadata and unknown geometry is unavailable",
         %{organization: org, version: version} do
      route_fixture(org.id, version.id, %{route_id: "r1"})

      pattern =
        route_pattern_fixture(org.id, version.id, %{
          route_pattern_id: "p1",
          route_id: "r1",
          direction_id: 0
        })

      stop_fixture(org.id, version.id, %{
        stop_id: "a",
        stop_lat: Decimal.new("1.0"),
        stop_lon: Decimal.new("2.0")
      })

      # Stored stop with known-absent coordinates.
      Repo.insert!(%Stop{
        organization_id: org.id,
        gtfs_version_id: version.id,
        stop_id: "s",
        stop_name: "No coordinates"
      })

      # Occurrence naming a stop with no row at all: unknown geometry.
      route_pattern_stop_fixture(pattern, "a", 1)
      route_pattern_stop_fixture(pattern, "s", 2)
      route_pattern_stop_fixture(pattern, "ghost", 3)

      # A referenced shape without rows is known absent, not unknown.
      trip_for_pattern(org, version, "r1", "p1", "sh_missing")

      assert {:ok, map} = Gtfs.route_map(org.id, version.id, "r1")
      [pattern_map] = map.patterns

      assert [
               %{position: 1, stop_id: "a", coordinates: [2.0, 1.0]},
               %{
                 position: 2,
                 stop_id: "s",
                 unlocated: [%{ref: "s", reason: :coordinates_absent}]
               },
               %{
                 position: 3,
                 stop_id: "ghost",
                 unlocated: [%{ref: "ghost", reason: :stop_not_found}]
               }
             ] = pattern_map.visits

      # Missing coordinates never draw a bogus connector: no coordinates key at
      # all, only explicit unlocated metadata.
      assert [
               %{
                 source: :stop_pair,
                 status: :missing,
                 from_position: 1,
                 to_position: 2,
                 unlocated: [%{ref: "s", reason: :coordinates_absent}]
               },
               %{
                 source: :stop_pair,
                 status: :unavailable,
                 from_position: 2,
                 to_position: 3,
                 unlocated: unlocated
               }
             ] = pattern_map.sections

      refute Enum.any?(pattern_map.sections, &Map.has_key?(&1, :coordinates))

      refute Enum.any?(
               pattern_map.visits,
               &(Map.has_key?(&1, :unlocated) and Map.has_key?(&1, :coordinates))
             )

      # Unknown geometry is unavailable, never fabricated as missing or saved.
      assert %{ref: "ghost", reason: :stop_not_found} in unlocated

      assert [
               %{
                 source: :imported_shape,
                 status: :missing,
                 shape_id: "sh_missing",
                 unlocated: [%{ref: "sh_missing", reason: :shape_points_absent}]
               }
             ] = map.imported_shape_variants

      refute Map.has_key?(hd(map.imported_shape_variants), :coordinates)
    end

    test "preserves loops with distinct occurrence identity for repeated stops",
         %{organization: org, version: version} do
      route_fixture(org.id, version.id, %{route_id: "r1"})

      pattern =
        route_pattern_fixture(org.id, version.id, %{
          route_pattern_id: "loop",
          route_id: "r1",
          direction_id: 0
        })

      stop_fixture(org.id, version.id, %{
        stop_id: "a",
        stop_lat: Decimal.new("1.0"),
        stop_lon: Decimal.new("2.0")
      })

      stop_fixture(org.id, version.id, %{
        stop_id: "b",
        stop_lat: Decimal.new("1.5"),
        stop_lon: Decimal.new("2.5")
      })

      route_pattern_stop_fixture(pattern, "a", 1)
      route_pattern_stop_fixture(pattern, "b", 2)
      route_pattern_stop_fixture(pattern, "a", 3)

      assert {:ok, map} = Gtfs.route_map(org.id, version.id, "r1")
      [pattern_map] = map.patterns

      # The repeated stop keeps two occurrence identities and the closing
      # connector back to the first stop is retained.
      assert Enum.map(pattern_map.visits, &{&1.position, &1.stop_id}) == [
               {1, "a"},
               {2, "b"},
               {3, "a"}
             ]

      assert Enum.map(pattern_map.sections, &{&1.from_position, &1.to_position, &1.status}) == [
               {1, 2, :saved},
               {2, 3, :saved}
             ]
    end

    test "foreign, unpublished and unknown scopes return bare not-found", %{
      organization: org,
      version: version
    } do
      route_fixture(org.id, version.id, %{route_id: "r1"})

      other_org = organization_fixture()
      other_version = gtfs_version_fixture(other_org.id)
      route_fixture(other_org.id, other_version.id, %{route_id: "r1"})

      {:ok, staging} =
        Versions.create_staging_gtfs_version(org.id, %{name: "Staging #{System.unique_integer()}"})

      route_fixture(org.id, staging.id, %{route_id: "r1"})

      assert Gtfs.route_map(org.id, version.id, "ghost") == {:error, :not_found}
      assert Gtfs.route_map(other_org.id, version.id, "r1") == {:error, :not_found}
      assert Gtfs.route_map(org.id, other_version.id, "r1") == {:error, :not_found}
      assert Gtfs.route_map(org.id, staging.id, "r1") == {:error, :not_found}
    end

    test "reads the whole route map in one fixed query set regardless of pattern count", %{
      organization: org,
      version: version
    } do
      small = route_fixture(org.id, version.id, %{route_id: "small"})
      big = route_fixture(org.id, version.id, %{route_id: "big"})

      stop_fixture(org.id, version.id, %{
        stop_id: "s1",
        stop_lat: Decimal.new("1.0"),
        stop_lon: Decimal.new("1.0")
      })

      stop_fixture(org.id, version.id, %{
        stop_id: "s2",
        stop_lat: Decimal.new("2.0"),
        stop_lon: Decimal.new("2.0")
      })

      for {route, pattern_count} <- [{small, 2}, {big, 5}], index <- 1..pattern_count do
        pattern =
          route_pattern_fixture(org.id, version.id, %{
            route_pattern_id: "#{route.route_id}_p#{index}",
            route_id: route.route_id,
            direction_id: 0
          })

        route_pattern_stop_fixture(pattern, "s1", 1)
        route_pattern_stop_fixture(pattern, "s2", 2)

        trip_for_pattern(
          org,
          version,
          route.route_id,
          pattern.route_pattern_id,
          "#{route.route_id}_sh"
        )
      end

      shape_point_fixture(org, version, "small_sh", 1, "1.0", "1.0")
      shape_point_fixture(org, version, "big_sh", 1, "1.0", "1.0")

      {{:ok, small_map}, small_queries} =
        count_queries(fn -> Gtfs.route_map(org.id, version.id, "small") end)

      {{:ok, big_map}, big_queries} =
        count_queries(fn -> Gtfs.route_map(org.id, version.id, "big") end)

      assert length(small_map.patterns) == 2
      assert length(big_map.patterns) == 5

      # Batched projection: the query set is a small constant, so a route with
      # more patterns cannot trigger per-pattern (or per-editor) reads.
      assert small_queries == big_queries
      assert big_queries <= 5
    end
  end

  describe "route context map through the ordinary public entrypoint" do
    # Scenario 1 through the production composition:
    # Gtfs.route_context_map/4 -> Routes.route_context_map/4 ->
    # GtfsPlanner.Gtfs.Routes.Map.route_context_map/4 (seam S-3, direct call).
    test "pages other routes in the viewport with deduplicated geometry, excluding the current route and foreign versions",
         %{organization: org, version: version} do
      route_fixture(org.id, version.id, %{route_id: "r1"})

      current_pattern =
        route_pattern_fixture(org.id, version.id, %{route_pattern_id: "p1", route_id: "r1"})

      stop_fixture(org.id, version.id, %{
        stop_id: "a",
        stop_lat: Decimal.new("1.0"),
        stop_lon: Decimal.new("2.0")
      })

      stop_fixture(org.id, version.id, %{
        stop_id: "b",
        stop_lat: Decimal.new("1.5"),
        stop_lon: Decimal.new("2.5")
      })

      stop_fixture(org.id, version.id, %{
        stop_id: "c",
        stop_lat: Decimal.new("1.8"),
        stop_lon: Decimal.new("3.0")
      })

      route_pattern_stop_fixture(current_pattern, "a", 1)
      route_pattern_stop_fixture(current_pattern, "b", 2)

      # Two context routes whose geometry sits in the viewport box, plus a
      # foreign tenant's route over the very same coordinates.
      route_fixture(org.id, version.id, %{route_id: "c1"})

      context_pattern =
        route_pattern_fixture(org.id, version.id, %{
          route_pattern_id: "cp1",
          route_id: "c1",
          route_pattern_name: "Context one"
        })

      route_pattern_stop_fixture(context_pattern, "b", 1)
      route_pattern_stop_fixture(context_pattern, "c", 2)

      shape_point_fixture(org, version, "csh1", 1, "1.1", "2.1")
      shape_point_fixture(org, version, "csh1", 2, "1.2", "2.2")

      # Two trips repeating one imported shape: geometry stays one entry.
      trip_for_pattern(org, version, "c1", "cp1", "csh1")
      trip_for_pattern(org, version, "c1", "cp1", "csh1")

      route_fixture(org.id, version.id, %{route_id: "c2"})

      context_pattern_two =
        route_pattern_fixture(org.id, version.id, %{
          route_pattern_id: "cp2",
          route_id: "c2"
        })

      route_pattern_stop_fixture(context_pattern_two, "a", 1)
      route_pattern_stop_fixture(context_pattern_two, "b", 2)

      other_org = organization_fixture()
      other_version = gtfs_version_fixture(other_org.id)
      route_fixture(other_org.id, other_version.id, %{route_id: "f1"})

      foreign_pattern =
        route_pattern_fixture(other_org.id, other_version.id, %{
          route_pattern_id: "fp1",
          route_id: "f1"
        })

      stop_fixture(other_org.id, other_version.id, %{
        stop_id: "a",
        stop_lat: Decimal.new("1.0"),
        stop_lon: Decimal.new("2.0")
      })

      stop_fixture(other_org.id, other_version.id, %{
        stop_id: "b",
        stop_lat: Decimal.new("1.5"),
        stop_lon: Decimal.new("2.5")
      })

      route_pattern_stop_fixture(foreign_pattern, "a", 1)
      route_pattern_stop_fixture(foreign_pattern, "b", 2)

      bounds = %{north: 2.0, south: 1.0, east: 3.5, west: 2.0}

      assert {:ok, context} =
               Gtfs.route_context_map(org.id, version.id, "r1", %{bounds: bounds, cursor: nil})

      assert context.status == :ok
      assert context.partial == false
      assert context.next_cursor == nil

      # Deterministic id order; the current route and the foreign tenant's
      # route never appear, no matter whose geometry sits in the box.
      assert Enum.map(context.routes, & &1.route_id) == ["c1", "c2"]

      [one, two] = context.routes

      assert %{
               route_uuid: _,
               route_id: "c1",
               route_short_name: route_short_name,
               route_long_name: route_long_name,
               route_color: route_color,
               route_text_color: route_text_color,
               active: true,
               sections: sections,
               imported_shape_variants: variants
             } = one

      assert is_binary(route_short_name) or is_nil(route_short_name)
      assert is_binary(route_long_name) or is_nil(route_long_name)
      assert is_binary(route_color) or is_nil(route_color)
      assert is_binary(route_text_color) or is_nil(route_text_color)

      # Connector sections keep the same source/status truthfulness; the
      # repeated trips' shared shape contributes exactly one variant entry.
      assert [%{source: :stop_pair, status: :saved, coordinates: coordinates}] = sections
      assert coordinates == [[2.5, 1.5], [3.0, 1.8]]

      assert [
               %{
                 source: :imported_shape,
                 status: :saved,
                 shape_id: "csh1",
                 coordinates: [[2.1, 1.1], [2.2, 1.2]]
               }
             ] = variants

      assert [%{source: :stop_pair, status: :saved}] = two.sections
      assert two.imported_shape_variants == []

      # A foreign scope is not found, exactly like route_map/3.
      assert Gtfs.route_context_map(org.id, version.id, "ghost", %{bounds: bounds, cursor: nil}) ==
               {:error, :not_found}
    end

    test "pagination is a deterministic keyset: partial pages continue without overlap",
         %{organization: org, version: version} do
      route_fixture(org.id, version.id, %{route_id: "r1"})

      pattern =
        route_pattern_fixture(org.id, version.id, %{route_pattern_id: "p1", route_id: "r1"})

      stop_fixture(org.id, version.id, %{
        stop_id: "a",
        stop_lat: Decimal.new("1.0"),
        stop_lon: Decimal.new("2.0")
      })

      stop_fixture(org.id, version.id, %{
        stop_id: "b",
        stop_lat: Decimal.new("1.5"),
        stop_lon: Decimal.new("2.5")
      })

      route_pattern_stop_fixture(pattern, "a", 1)
      route_pattern_stop_fixture(pattern, "b", 2)

      for index <- 1..55 do
        route_id = "ctx_#{String.pad_leading(Integer.to_string(index), 2, "0")}"
        route_fixture(org.id, version.id, %{route_id: route_id})

        context_pattern =
          route_pattern_fixture(org.id, version.id, %{
            route_pattern_id: "#{route_id}_p",
            route_id: route_id
          })

        route_pattern_stop_fixture(context_pattern, "a", 1)
        route_pattern_stop_fixture(context_pattern, "b", 2)
      end

      bounds = %{north: 2.0, south: 1.0, east: 3.0, west: 2.0}

      assert {:ok, first} =
               Gtfs.route_context_map(org.id, version.id, "r1", %{bounds: bounds, cursor: nil})

      assert length(first.routes) == 50
      assert first.partial == true
      first_ids = Enum.map(first.routes, & &1.route_id)
      assert first_ids == Enum.sort(first_ids)
      assert List.first(first_ids) == "ctx_01"
      assert List.last(first_ids) == "ctx_50"
      assert first.next_cursor == "ctx1:ctx_50"

      # Re-asking for the same page returns the same page: the cursor is a
      # stable keyset over deterministic ids, not a sliding offset.
      assert {:ok, first_again} =
               Gtfs.route_context_map(org.id, version.id, "r1", %{
                 bounds: bounds,
                 cursor: nil
               })

      assert first_again.routes == first.routes

      assert {:ok, second} =
               Gtfs.route_context_map(org.id, version.id, "r1", %{
                 bounds: bounds,
                 cursor: first.next_cursor
               })

      second_ids = Enum.map(second.routes, & &1.route_id)
      assert second_ids == Enum.sort(second_ids)
      assert List.first(second_ids) == "ctx_51"
      assert List.last(second_ids) == "ctx_55"
      assert second.partial == false
      assert second.next_cursor == nil
      assert MapSet.disjoint?(MapSet.new(first_ids), MapSet.new(second_ids))
    end

    test "the current route stays complete while its context pages", %{
      organization: org,
      version: version
    } do
      route_fixture(org.id, version.id, %{route_id: "r1"})

      for index <- 1..3 do
        pattern =
          route_pattern_fixture(org.id, version.id, %{
            route_pattern_id: "p#{index}",
            route_id: "r1"
          })

        route_pattern_stop_fixture(pattern, "a", 1)
        route_pattern_stop_fixture(pattern, "b", 2)
      end

      stop_fixture(org.id, version.id, %{
        stop_id: "a",
        stop_lat: Decimal.new("1.0"),
        stop_lon: Decimal.new("2.0")
      })

      stop_fixture(org.id, version.id, %{
        stop_id: "b",
        stop_lat: Decimal.new("1.5"),
        stop_lon: Decimal.new("2.5")
      })

      for index <- 1..55 do
        route_id = "ctx_#{String.pad_leading(Integer.to_string(index), 2, "0")}"
        route_fixture(org.id, version.id, %{route_id: route_id})

        context_pattern =
          route_pattern_fixture(org.id, version.id, %{
            route_pattern_id: "#{route_id}_p",
            route_id: route_id
          })

        route_pattern_stop_fixture(context_pattern, "a", 1)
        route_pattern_stop_fixture(context_pattern, "b", 2)
      end

      bounds = %{north: 2.0, south: 1.0, east: 3.0, west: 2.0}

      assert {:ok, context} =
               Gtfs.route_context_map(org.id, version.id, "r1", %{bounds: bounds, cursor: nil})

      assert length(context.routes) == 50
      refute "r1" in Enum.map(context.routes, & &1.route_id)

      # Paging the context never truncates the current route's own read.
      assert {:ok, route_map} = Gtfs.route_map(org.id, version.id, "r1")
      assert length(route_map.patterns) == 3
    end

    test "malformed bounds and cursors are rejected without a read", %{
      organization: org,
      version: version
    } do
      route_fixture(org.id, version.id, %{route_id: "r1"})

      good = %{north: 2.0, south: 1.0, east: 3.0, west: 2.0}

      assert Gtfs.route_context_map(org.id, version.id, "r1", %{bounds: good, cursor: nil}) !=
               {:error, :invalid_bounds}

      for bad_bounds <- [
            %{},
            %{north: 2.0, south: 1.0, east: 3.0},
            %{north: "2.0", south: 1.0, east: 3.0, west: 2.0},
            %{north: 1.0, south: 2.0, east: 3.0, west: 2.0},
            %{north: 2.0, south: 1.0, east: 1.0, west: 3.0},
            %{north: 91.0, south: 1.0, east: 3.0, west: 2.0},
            %{north: 2.0, south: -91.0, east: 3.0, west: 2.0},
            %{north: 2.0, south: 1.0, east: 200.0, west: 2.0},
            %{north: 2.0, south: 1.0, east: 3.0, west: -200.0}
          ] do
        assert Gtfs.route_context_map(org.id, version.id, "r1", %{bounds: bad_bounds, cursor: nil}) ==
                 {:error, :invalid_bounds}
      end

      for bad_cursor <- ["junk", "ctx1:", "ctx2:ctx_01", 42, %{}] do
        assert Gtfs.route_context_map(org.id, version.id, "r1", %{
                 bounds: good,
                 cursor: bad_cursor
               }) ==
                 {:error, :invalid_cursor}
      end

      # A shaped-but-empty opts map is malformed too.
      assert Gtfs.route_context_map(org.id, version.id, "r1", %{}) == {:error, :invalid_bounds}
    end

    test "viewport selection returns only routes whose geometry is inside the box",
         %{organization: org, version: version} do
      route_fixture(org.id, version.id, %{route_id: "r1"})

      pattern =
        route_pattern_fixture(org.id, version.id, %{route_pattern_id: "p1", route_id: "r1"})

      stop_fixture(org.id, version.id, %{
        stop_id: "a",
        stop_lat: Decimal.new("1.0"),
        stop_lon: Decimal.new("2.0")
      })

      stop_fixture(org.id, version.id, %{
        stop_id: "b",
        stop_lat: Decimal.new("1.5"),
        stop_lon: Decimal.new("2.5")
      })

      stop_fixture(org.id, version.id, %{
        stop_id: "far",
        stop_lat: Decimal.new("50.0"),
        stop_lon: Decimal.new("20.0")
      })

      route_pattern_stop_fixture(pattern, "a", 1)
      route_pattern_stop_fixture(pattern, "b", 2)

      inside_pattern =
        route_pattern_fixture(org.id, version.id, %{route_pattern_id: "ip", route_id: "inside"})

      route_fixture(org.id, version.id, %{route_id: "inside"})
      route_pattern_stop_fixture(inside_pattern, "a", 1)
      route_pattern_stop_fixture(inside_pattern, "b", 2)

      outside_pattern =
        route_pattern_fixture(org.id, version.id, %{route_pattern_id: "op", route_id: "outside"})

      route_fixture(org.id, version.id, %{route_id: "outside"})
      route_pattern_stop_fixture(outside_pattern, "far", 1)

      # A route with no geometry at all is never context.
      route_fixture(org.id, version.id, %{route_id: "empty"})

      bounds = %{north: 2.0, south: 1.0, east: 3.0, west: 2.0}

      assert {:ok, context} =
               Gtfs.route_context_map(org.id, version.id, "r1", %{bounds: bounds, cursor: nil})

      assert Enum.map(context.routes, & &1.route_id) == ["inside"]

      narrow = %{north: 60.0, south: 40.0, east: 30.0, west: 10.0}

      assert {:ok, shifted} =
               Gtfs.route_context_map(org.id, version.id, "r1", %{bounds: narrow, cursor: nil})

      assert Enum.map(shifted.routes, & &1.route_id) == ["outside"]

      nowhere = %{north: -1.0, south: -2.0, east: -1.0, west: -2.0}

      assert {:ok, empty} =
               Gtfs.route_context_map(org.id, version.id, "r1", %{bounds: nowhere, cursor: nil})

      assert empty.routes == []
      assert empty.partial == false
      assert empty.next_cursor == nil
    end

    test "trip multiplicity never multiplies geometry or queries on a page", %{
      organization: org,
      version: version
    } do
      route_fixture(org.id, version.id, %{route_id: "r1"})

      pattern =
        route_pattern_fixture(org.id, version.id, %{route_pattern_id: "p1", route_id: "r1"})

      stop_fixture(org.id, version.id, %{
        stop_id: "a",
        stop_lat: Decimal.new("1.0"),
        stop_lon: Decimal.new("2.0")
      })

      stop_fixture(org.id, version.id, %{
        stop_id: "b",
        stop_lat: Decimal.new("1.5"),
        stop_lon: Decimal.new("2.5")
      })

      route_pattern_stop_fixture(pattern, "a", 1)
      route_pattern_stop_fixture(pattern, "b", 2)

      route_fixture(org.id, version.id, %{route_id: "few_trips"})

      few_pattern =
        route_pattern_fixture(org.id, version.id, %{
          route_pattern_id: "few_p",
          route_id: "few_trips"
        })

      route_pattern_stop_fixture(few_pattern, "a", 1)
      route_pattern_stop_fixture(few_pattern, "b", 2)
      trip_for_pattern(org, version, "few_trips", "few_p", "sh_few")
      shape_point_fixture(org, version, "sh_few", 1, "1.1", "2.1")

      route_fixture(org.id, version.id, %{route_id: "many_trips"})

      many_pattern =
        route_pattern_fixture(org.id, version.id, %{
          route_pattern_id: "many_p",
          route_id: "many_trips"
        })

      route_pattern_stop_fixture(many_pattern, "a", 1)
      route_pattern_stop_fixture(many_pattern, "b", 2)

      for _index <- 1..3 do
        trip_for_pattern(org, version, "many_trips", "many_p", "sh_many")
      end

      shape_point_fixture(org, version, "sh_many", 1, "1.2", "2.2")

      bounds = %{north: 2.0, south: 1.0, east: 3.0, west: 2.0}

      assert {:ok, context} =
               Gtfs.route_context_map(org.id, version.id, "r1", %{bounds: bounds, cursor: nil})

      many = Enum.find(context.routes, &(&1.route_id == "many_trips"))
      few = Enum.find(context.routes, &(&1.route_id == "few_trips"))

      # Three trips on one shape, one geometry entry (AC-27/AC-30 direction;
      # step 32 measures the workload).
      assert length(many.imported_shape_variants) == 1
      assert length(few.imported_shape_variants) == 1

      {{:ok, _}, many_trip_queries} =
        count_queries(fn ->
          Gtfs.route_context_map(org.id, version.id, "r1", %{bounds: bounds, cursor: nil})
        end)

      Repo.delete_all(
        from(trip in GtfsPlanner.Gtfs.Trip,
          where: trip.route_id == "many_trips" and trip.organization_id == ^org.id
        )
      )

      {{:ok, _}, few_trip_queries} =
        count_queries(fn ->
          Gtfs.route_context_map(org.id, version.id, "r1", %{bounds: bounds, cursor: nil})
        end)

      assert few_trip_queries == many_trip_queries
      assert many_trip_queries <= 6
    end
  end

  defp trip_for_pattern(org, version, route_id, pattern_id, shape_id) do
    trip =
      trip_fixture(org.id, version.id, route_id, %{
        trip_id: "trip_#{System.unique_integer([:positive])}",
        shape_id: shape_id
      })

    Repo.update!(Ecto.Changeset.change(trip, route_pattern_id: pattern_id))
  end

  defp shape_point_fixture(org, version, shape_id, sequence, lat, lon) do
    Repo.insert!(%Shape{
      organization_id: org.id,
      gtfs_version_id: version.id,
      shape_id: shape_id,
      shape_pt_lat: Decimal.new(lat),
      shape_pt_lon: Decimal.new(lon),
      shape_pt_sequence: sequence
    })
  end

  defp count_queries(fun) do
    test_pid = self()
    handler_id = "map-query-count-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler_id,
      [:gtfs_planner, :repo, :query],
      fn _event, _measurements, _metadata, _config -> send(test_pid, :repo_query) end,
      nil
    )

    try do
      result = fun.()
      {result, drain_queries(0)}
    after
      :telemetry.detach(handler_id)
    end
  end

  defp drain_queries(count) do
    receive do
      :repo_query -> drain_queries(count + 1)
    after
      0 -> count
    end
  end
end
