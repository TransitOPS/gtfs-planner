defmodule GtfsPlanner.Gtfs.Routes.MapLeftOutTest do
  @moduledoc """
  The route map projection's `outside_trip_count` (spec 27, step 17, EV-17).

  Every imported line variant reports how many of its trips sit outside every
  route pattern, and `route_pattern_ids` keeps naming only the patterns those
  trips are linked to. Read through the production composition
  `Gtfs.route_map/3` — no test-only wiring.
  """

  use GtfsPlanner.DataCase

  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.Shape
  alias GtfsPlanner.Gtfs.Trip

  setup do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    %{organization: organization, version: version}
  end

  describe "imported lines outside patterns through the ordinary public entrypoint" do
    test "counts the custom trips of a shape with no linked pattern and reports zero for a linked shape",
         %{organization: org, version: version} do
      route_fixture(org.id, version.id, %{route_id: "r1"})

      pattern_a =
        route_pattern_fixture(org.id, version.id, %{
          route_pattern_id: "A",
          route_id: "r1",
          direction_id: 0
        })

      timing_a = timed_pattern_fixture(pattern_a)

      shape_points(org, version, "S", [{1, "1.0", "2.0"}, {2, "1.5", "2.5"}])
      shape_points(org, version, "T", [{1, "3.0", "4.0"}, {2, "3.5", "4.5"}])

      # Shape T is used by pattern A's linked trips.
      linked_trip(org, version, "r1", "A", timing_a.id, "T")
      linked_trip(org, version, "r1", "A", timing_a.id, "T")

      # Shape S is used only by trips outside every pattern: no route pattern id
      # and a custom derivation state.
      for _index <- 1..18 do
        custom_trip(org, version, "r1", "S")
      end

      assert {:ok, map} = Gtfs.route_map(org.id, version.id, "r1")

      # Deterministic shape-id order: S is variant 1, T is variant 2.
      assert [shape_s, shape_t] = map.imported_shape_variants
      assert pattern_a.route_pattern_id == "A"

      assert shape_s.shape_id == "S"
      assert shape_s.outside_trip_count == 18
      # No trip on S is linked to a pattern, so the pattern list stays empty
      # rather than carrying a nil.
      assert shape_s.route_pattern_ids == []
      refute Enum.any?(shape_s.route_pattern_ids, &is_nil/1)

      assert shape_t.shape_id == "T"
      assert shape_t.outside_trip_count == 0
      assert shape_t.route_pattern_ids == ["A"]

      # The count is added to the variant, never replacing its geometry or
      # truthfulness metadata.
      assert shape_s.status == :saved
      assert shape_s.coordinates == [[2.0, 1.0], [2.5, 1.5]]
      assert shape_s.source == :imported_shape
    end

    test "a shape used by both linked and custom trips reports both", %{
      organization: org,
      version: version
    } do
      route_fixture(org.id, version.id, %{route_id: "r1"})

      pattern_a =
        route_pattern_fixture(org.id, version.id, %{
          route_pattern_id: "A",
          route_id: "r1",
          direction_id: 0
        })

      timing_a = timed_pattern_fixture(pattern_a)

      shape_points(org, version, "S", [{1, "1.0", "2.0"}, {2, "1.5", "2.5"}])

      linked_trip(org, version, "r1", "A", timing_a.id, "S")
      custom_trip(org, version, "r1", "S")
      custom_trip(org, version, "r1", "S")

      assert {:ok, map} = Gtfs.route_map(org.id, version.id, "r1")

      assert [variant] = map.imported_shape_variants
      # Three trips on one shape: two outside patterns, one linked to A.
      assert variant.outside_trip_count == 2
      assert variant.route_pattern_ids == ["A"]
    end

    test "another route's custom trips are not counted", %{organization: org, version: version} do
      route_fixture(org.id, version.id, %{route_id: "r1"})
      route_fixture(org.id, version.id, %{route_id: "r2"})

      pattern_a =
        route_pattern_fixture(org.id, version.id, %{
          route_pattern_id: "A",
          route_id: "r1",
          direction_id: 0
        })

      timing_a = timed_pattern_fixture(pattern_a)

      shape_points(org, version, "S", [{1, "1.0", "2.0"}, {2, "1.5", "2.5"}])

      # The same shape id carries outside trips on the other route.
      linked_trip(org, version, "r1", "A", timing_a.id, "S")
      custom_trip(org, version, "r1", "S")

      for _index <- 1..5 do
        custom_trip(org, version, "r2", "S")
      end

      assert {:ok, map} = Gtfs.route_map(org.id, version.id, "r1")

      assert [variant] = map.imported_shape_variants
      assert variant.outside_trip_count == 1
      assert variant.route_pattern_ids == ["A"]

      assert {:ok, other_map} = Gtfs.route_map(org.id, version.id, "r2")

      assert [other_variant] = other_map.imported_shape_variants
      assert other_variant.outside_trip_count == 5
      assert other_variant.route_pattern_ids == []
    end
  end

  # A linked trip sits on a pattern's timing (the landed `trips` check
  # constraint requires it), so its imported line names that pattern.
  defp linked_trip(org, version, route_id, pattern_id, timing_id, shape_id) do
    insert_trip(org, version, route_id, %{
      shape_id: shape_id,
      route_pattern_id: pattern_id,
      timed_pattern_id: timing_id,
      pattern_derivation_state: "linked"
    })
  end

  # A custom trip is outside every pattern: no pattern, no timing, and the
  # reason the import left it out.
  defp custom_trip(org, version, route_id, shape_id) do
    insert_trip(org, version, route_id, %{
      shape_id: shape_id,
      pattern_derivation_state: "custom",
      pattern_derivation_reason: "no_direction"
    })
  end

  defp insert_trip(org, version, route_id, attrs) do
    %Trip{
      organization_id: org.id,
      gtfs_version_id: version.id,
      route_id: route_id,
      trip_id: "trip_#{System.unique_integer([:positive])}",
      service_id: "service_1",
      trip_headsign: "Downtown"
    }
    |> struct!(attrs)
    |> Repo.insert!()
  end

  defp shape_points(org, version, shape_id, points) do
    for {sequence, lat, lon} <- points do
      Repo.insert!(%Shape{
        organization_id: org.id,
        gtfs_version_id: version.id,
        shape_id: shape_id,
        shape_pt_lat: Decimal.new(lat),
        shape_pt_lon: Decimal.new(lon),
        shape_pt_sequence: sequence
      })
    end

    :ok
  end
end
