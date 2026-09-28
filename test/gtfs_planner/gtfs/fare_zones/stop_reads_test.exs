defmodule GtfsPlanner.Gtfs.FareZones.StopReadsTest do
  @moduledoc """
  Merge evidence (EV-5) for the workspace's stop reads, matching IDs and map
  points.

  Every read covers the version's boardable stops only and every expected literal
  below is hand-written fixture data, so the queries cannot confirm their own
  output.

  - A `{:zone, " A"}` filter returns the padded zone's stop and not `"A"`'s.
  - `:unassigned` returns only boardable stops without a zone.
  - Search is case-insensitive and treats `%` and `_` literally on names and IDs.
  - Stations, entrances, generic nodes and boarding areas never appear.
  - Pages are ordered by name (missing names last, then stop ID) and a page past
    the end is clamped to the last page.
  - `matching_stop_ids/3` returns the whole filtered set, and `:ids` drops
    foreign-organization and non-boardable UUIDs.
  - Map points exclude stops missing either coordinate and carry floats.
  - `without_location_count` counts filter matches without coordinates, ignoring
    the search.
  - A second organization and a second version with identical stop IDs
    contribute nothing.
  """
  use GtfsPlanner.DataCase, async: true

  alias GtfsPlanner.Gtfs.FareZones
  alias GtfsPlanner.Gtfs.Stop
  alias GtfsPlanner.OrganizationsFixtures
  alias GtfsPlanner.Repo
  alias GtfsPlanner.VersionsFixtures

  setup do
    organization = OrganizationsFixtures.organization_fixture()
    version = VersionsFixtures.gtfs_version_fixture(organization.id)

    %{organization: organization, version: version}
  end

  test "returns only the stop whose zone ID is exactly ` A`", %{
    organization: organization,
    version: version
  } do
    [padded, plain, _unassigned] =
      insert_stops(organization, version, [
        %{stop_id: "p-space", stop_name: "Padded", zone_id: " A"},
        %{stop_id: "p-plain", stop_name: "Plain", zone_id: "A"},
        %{stop_id: "p-none", stop_name: "Unassigned", zone_id: nil}
      ])

    page = FareZones.list_stops(organization.id, version.id, filter: {:zone, " A"})

    assert page.entries == [
             %{
               id: padded.id,
               stop_id: "p-space",
               stop_name: "Padded",
               parent_station: nil,
               platform_code: nil,
               zone_id: " A",
               located?: false
             }
           ]

    assert page.total_count == 1
    assert page.page == 1
    assert page.per_page == 100
    assert page.without_location_count == 1

    plain_page = FareZones.list_stops(organization.id, version.id, filter: {:zone, "A"})
    assert Enum.map(plain_page.entries, & &1.stop_id) == ["p-plain"]
    assert plain_page.total_count == 1

    assert FareZones.matching_stop_ids(organization.id, version.id, filter: {:zone, " A"}) ==
             [padded.id]

    assert FareZones.matching_stop_ids(organization.id, version.id, filter: {:zone, "A"}) ==
             [plain.id]

    assert FareZones.matching_stop_ids(organization.id, version.id, filter: {:zone, "Missing"}) ==
             []

    assert FareZones.matching_stop_ids(organization.id, version.id, filter: {:zone, "A "}) == []
  end

  test "returns only boardable stops without a zone for :unassigned", %{
    organization: organization,
    version: version
  } do
    [unassigned, assigned, _station] =
      insert_stops(organization, version, [
        %{stop_id: "b-1", stop_name: "Alpha unassigned", zone_id: nil},
        %{stop_id: "b-2", stop_name: "Beta assigned", zone_id: "A"},
        %{stop_id: "st-1", stop_name: "Gamma station", location_type: 1, zone_id: nil}
      ])

    page = FareZones.list_stops(organization.id, version.id, filter: :unassigned)

    assert Enum.map(page.entries, & &1.stop_id) == ["b-1"]
    assert page.total_count == 1
    assert page.without_location_count == 1

    assert FareZones.matching_stop_ids(organization.id, version.id, filter: :unassigned) ==
             [unassigned.id]

    # `:all` is the default and includes the assigned stop.
    all = FareZones.list_stops(organization.id, version.id)

    assert Enum.map(all.entries, & &1.stop_id) == ["b-1", "b-2"]
    assert all.total_count == 2
    assert all.without_location_count == 2

    assert FareZones.matching_stop_ids(organization.id, version.id) ==
             [unassigned.id, assigned.id]
  end

  test "searches names and stop IDs case-insensitively with literal % and _", %{
    organization: organization,
    version: version
  } do
    insert_stops(organization, version, [
      %{stop_id: "p-1", stop_name: "Gate 50%", zone_id: nil},
      %{stop_id: "p-2", stop_name: "Gate 500", zone_id: nil},
      %{stop_id: "p-3", stop_name: "a_b", zone_id: nil},
      %{stop_id: "p-4", stop_name: "axb", zone_id: nil},
      %{stop_id: "p-5", stop_name: "Depot", zone_id: nil}
    ])

    assert names(FareZones.list_stops(organization.id, version.id, q: "50%")) == ["Gate 50%"]
    assert names(FareZones.list_stops(organization.id, version.id, q: "a_b")) == ["a_b"]
    assert names(FareZones.list_stops(organization.id, version.id, q: "%")) == ["Gate 50%"]
    assert names(FareZones.list_stops(organization.id, version.id, q: "_")) == ["a_b"]
    assert names(FareZones.list_stops(organization.id, version.id, q: "\\")) == []

    # Case-insensitive on both the name and the stop ID.
    assert names(FareZones.list_stops(organization.id, version.id, q: "GATE")) ==
             ["Gate 50%", "Gate 500"]

    assert names(FareZones.list_stops(organization.id, version.id, q: "p-5")) == ["Depot"]
    assert names(FareZones.list_stops(organization.id, version.id, q: "nope")) == []

    searched = FareZones.list_stops(organization.id, version.id, q: "GATE")
    assert searched.total_count == 2
    # The unlocated count ignores the search, so all five stops are counted.
    assert searched.without_location_count == 5

    # An empty search is no search.
    assert length(FareZones.list_stops(organization.id, version.id, q: "").entries) == 5

    assert length(FareZones.matching_stop_ids(organization.id, version.id, q: "50%")) == 1
    assert length(FareZones.matching_stop_ids(organization.id, version.id, q: "GATE")) == 2
  end

  test "never returns stations, entrances or other location types", %{
    organization: organization,
    version: version
  } do
    [boardable, _station, _entrance, _node, _boarding_area] =
      insert_stops(organization, version, [
        %{stop_id: "b-1", stop_name: "Boardable", zone_id: "A", located_at: {"42.1", "-71.1"}},
        %{
          stop_id: "st-1",
          stop_name: "Station",
          location_type: 1,
          zone_id: "A",
          located_at: {"42.2", "-71.2"}
        },
        %{
          stop_id: "en-1",
          stop_name: "Entrance",
          location_type: 2,
          zone_id: "A",
          located_at: {"42.3", "-71.3"}
        },
        %{
          stop_id: "no-1",
          stop_name: "Node",
          location_type: 3,
          zone_id: "A",
          located_at: {"42.4", "-71.4"}
        },
        %{
          stop_id: "ba-1",
          stop_name: "Boarding area",
          location_type: 4,
          zone_id: "A",
          located_at: {"42.5", "-71.5"}
        }
      ])

    all = FareZones.list_stops(organization.id, version.id)

    assert Enum.map(all.entries, & &1.stop_id) == ["b-1"]
    assert all.total_count == 1
    assert all.without_location_count == 0

    assert Enum.map(
             FareZones.list_stops(organization.id, version.id, filter: {:zone, "A"}).entries,
             & &1.stop_id
           ) == ["b-1"]

    assert FareZones.list_stops(organization.id, version.id, filter: :unassigned).entries == []

    assert FareZones.matching_stop_ids(organization.id, version.id) == [boardable.id]

    assert [[id, stop_id, stop_name, lat, lon, zone_id, parent_station]] =
             FareZones.list_stop_points(organization.id, version.id)

    assert id == boardable.id
    assert stop_id == "b-1"
    assert stop_name == "Boardable"
    assert is_float(lat)
    assert is_float(lon)
    assert_in_delta lat, 42.1, 1.0e-9
    assert_in_delta lon, -71.1, 1.0e-9
    assert zone_id == "A"
    assert parent_station == nil
  end

  test "orders the page and clamps a page past the end", %{
    organization: organization,
    version: version
  } do
    insert_stops(
      organization,
      version,
      for n <- 1..150 do
        %{stop_id: "p-#{pad(n)}", stop_name: "Stop #{pad(n)}", zone_id: "A"}
      end
    )

    first =
      FareZones.list_stops(organization.id, version.id,
        filter: {:zone, "A"},
        page: 1,
        per_page: 100
      )

    assert length(first.entries) == 100
    assert first.page == 1
    assert first.per_page == 100
    assert first.total_count == 150
    assert Enum.map(first.entries, & &1.stop_id) == Enum.map(1..100, fn n -> "p-#{pad(n)}" end)

    second =
      FareZones.list_stops(organization.id, version.id,
        filter: {:zone, "A"},
        page: 2,
        per_page: 100
      )

    assert length(second.entries) == 50
    assert second.page == 2
    assert first.total_count == second.total_count

    assert Enum.map(second.entries, & &1.stop_id) == Enum.map(101..150, fn n -> "p-#{pad(n)}" end)

    clamped =
      FareZones.list_stops(organization.id, version.id,
        filter: {:zone, "A"},
        page: 9,
        per_page: 100
      )

    assert clamped.page == 2
    assert clamped.entries == second.entries

    empty =
      FareZones.list_stops(organization.id, version.id,
        filter: {:zone, "Missing"},
        page: 7,
        per_page: 100
      )

    assert empty.entries == []
    assert empty.page == 1
    assert empty.total_count == 0
    assert empty.without_location_count == 0
  end

  test "orders tiers of equal names by stop ID with missing names last", %{
    organization: organization,
    version: version
  } do
    [null_1, null_2, alpha_2, alpha_1] =
      insert_stops(organization, version, [
        %{stop_id: "z-1", stop_name: nil, zone_id: "A"},
        %{stop_id: "z-2", stop_name: nil, zone_id: "A"},
        %{stop_id: "a-2", stop_name: "Alpha", zone_id: "A"},
        %{stop_id: "a-1", stop_name: "Alpha", zone_id: "A"}
      ])

    page = FareZones.list_stops(organization.id, version.id, filter: {:zone, "A"})

    assert Enum.map(page.entries, & &1.stop_id) == ["a-1", "a-2", "z-1", "z-2"]

    assert FareZones.matching_stop_ids(organization.id, version.id, filter: {:zone, "A"}) ==
             [alpha_1.id, alpha_2.id, null_1.id, null_2.id]
  end

  test "returns every matching ID and restricts to a client selection", %{
    organization: organization,
    version: version
  } do
    rows =
      insert_stops(
        organization,
        version,
        for n <- 1..250 do
          %{stop_id: "m-#{pad(n)}", stop_name: "Match #{pad(n)}", zone_id: "A"}
        end
      )

    ids =
      FareZones.matching_stop_ids(organization.id, version.id, filter: {:zone, "A"}, q: "match")

    assert length(ids) == 250
    assert Enum.sort(ids) == rows |> Enum.map(& &1.id) |> Enum.sort()

    valid = Enum.find(rows, &(&1.stop_id == "m-001"))
    second_match = Enum.find(rows, &(&1.stop_id == "m-002"))

    [station] =
      insert_stops(organization, version, [
        %{stop_id: "st-1", stop_name: "Station", location_type: 1, zone_id: "A"}
      ])

    foreign_organization = OrganizationsFixtures.organization_fixture()
    foreign_version = VersionsFixtures.gtfs_version_fixture(foreign_organization.id)

    [foreign] =
      insert_stops(foreign_organization, foreign_version, [
        %{stop_id: "m-002", stop_name: "Match 002", zone_id: "A"}
      ])

    assert FareZones.matching_stop_ids(organization.id, version.id,
             filter: {:zone, "A"},
             ids: [foreign.id, station.id, valid.id]
           ) == [valid.id]

    assert FareZones.matching_stop_ids(organization.id, version.id,
             filter: {:zone, "A"},
             ids: [valid.id, valid.id]
           ) == [valid.id]

    assert FareZones.matching_stop_ids(organization.id, version.id, filter: {:zone, "A"}, ids: []) ==
             []

    # `ids:` combines with the filter and the search.
    assert FareZones.matching_stop_ids(organization.id, version.id,
             filter: {:zone, "A"},
             q: "Match 001",
             ids: [valid.id, second_match.id]
           ) == [valid.id]
  end

  test "returns located boardable stops as float points ordered by stop ID", %{
    organization: organization,
    version: version
  } do
    [_padded, _no_coords, _latitude_only, located, _station] =
      insert_stops(organization, version, [
        %{
          stop_id: "p-5",
          stop_name: "Padded",
          zone_id: " A",
          located_at: {"42.5", "-71.25"}
        },
        %{stop_id: "p-1", stop_name: "No coords", zone_id: nil},
        %{stop_id: "p-3", stop_name: "Latitude only", zone_id: nil, located_at: {"42.0", nil}},
        %{
          stop_id: "p-2",
          stop_name: "Located",
          zone_id: "A",
          parent_station: "st-1",
          located_at: {"42.3601", "-71.0589"}
        },
        %{
          stop_id: "st-1",
          stop_name: "Station",
          location_type: 1,
          zone_id: "A",
          located_at: {"42.0", "-71.0"}
        }
      ])

    points = FareZones.list_stop_points(organization.id, version.id)

    assert Enum.map(points, fn [_, stop_id, _, _, _, _, _] -> stop_id end) == ["p-2", "p-5"]
    assert Enum.map(points, &length/1) == [7, 7]

    assert Enum.map(points, fn [_, _, _, lat, lon, _, _] -> {is_float(lat), is_float(lon)} end) ==
             [{true, true}, {true, true}]

    assert [id, stop_id, stop_name, lat, lon, zone_id, parent_station] = Enum.at(points, 0)
    assert id == located.id
    assert stop_id == "p-2"
    assert stop_name == "Located"
    assert_in_delta lat, 42.3601, 1.0e-9
    assert_in_delta lon, -71.0589, 1.0e-9
    assert zone_id == "A"
    assert parent_station == "st-1"

    assert [_, "p-5", "Padded", padded_lat, padded_lon, " A", nil] = Enum.at(points, 1)
    assert_in_delta padded_lat, 42.5, 1.0e-9
    assert_in_delta padded_lon, -71.25, 1.0e-9
  end

  test "counts filter matches without coordinates, ignoring the search", %{
    organization: organization,
    version: version
  } do
    insert_stops(organization, version, [
      %{stop_id: "p-1", stop_name: "Alpha one", zone_id: "A"},
      %{
        stop_id: "p-2",
        stop_name: "Alpha two",
        zone_id: "A",
        located_at: {"42.0", "-71.0"}
      },
      %{stop_id: "p-3", stop_name: "Beta", zone_id: "B"},
      %{stop_id: "p-4", stop_name: "Gamma", zone_id: nil, located_at: {nil, "-71.0"}},
      %{stop_id: "st-1", stop_name: "Station", location_type: 1, zone_id: "A"}
    ])

    page =
      FareZones.list_stops(organization.id, version.id, filter: {:zone, "A"}, q: "alpha")

    assert Enum.map(page.entries, & &1.stop_id) == ["p-1", "p-2"]
    assert page.total_count == 2
    assert page.without_location_count == 1

    all = FareZones.list_stops(organization.id, version.id, q: "alpha")

    assert all.total_count == 2
    assert all.without_location_count == 3

    unassigned = FareZones.list_stops(organization.id, version.id, filter: :unassigned)
    assert unassigned.without_location_count == 1
  end

  test "ignores a second version and a second organization with identical stop IDs", %{
    organization: organization,
    version: version
  } do
    other_version = VersionsFixtures.gtfs_version_fixture(organization.id)
    other_organization = OrganizationsFixtures.organization_fixture()
    other_organization_version = VersionsFixtures.gtfs_version_fixture(other_organization.id)

    insert_stops(organization, version, [
      %{stop_id: "p-1", stop_name: "Main", zone_id: "A", located_at: {"42.0", "-71.0"}},
      %{stop_id: "p-2", stop_name: "Plain", zone_id: nil}
    ])

    insert_stops(organization, other_version, [
      %{stop_id: "p-1", stop_name: "Other version", zone_id: "A", located_at: {"41.0", "-70.0"}}
    ])

    insert_stops(other_organization, other_organization_version, [
      %{stop_id: "p-1", stop_name: "Foreign", zone_id: "A", located_at: {"40.0", "-69.0"}}
    ])

    page = FareZones.list_stops(organization.id, version.id)

    assert Enum.map(page.entries, & &1.stop_id) == ["p-1", "p-2"]
    assert Enum.map(page.entries, & &1.stop_name) == ["Main", "Plain"]
    assert page.total_count == 2
    assert page.without_location_count == 1
    assert length(FareZones.matching_stop_ids(organization.id, version.id)) == 2
    assert length(FareZones.list_stop_points(organization.id, version.id)) == 1

    other_version_page = FareZones.list_stops(organization.id, other_version.id)

    assert Enum.map(other_version_page.entries, & &1.stop_id) == ["p-1"]
    assert Enum.map(other_version_page.entries, & &1.stop_name) == ["Other version"]
    assert other_version_page.total_count == 1
    assert other_version_page.without_location_count == 0

    empty_page = FareZones.list_stops(other_organization.id, version.id, filter: {:zone, "A"})

    assert empty_page.entries == []
    assert empty_page.total_count == 0
    assert empty_page.page == 1
    assert empty_page.without_location_count == 0

    assert FareZones.matching_stop_ids(other_organization.id, version.id) == []
    assert FareZones.list_stop_points(other_organization.id, version.id) == []
  end

  defp names(page), do: Enum.map(page.entries, & &1.stop_name)

  defp pad(n), do: String.pad_leading(Integer.to_string(n), 3, "0")

  defp insert_stops(organization, version, stops) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    rows =
      Enum.map(stops, fn stop ->
        {lat, lon} = Map.get(stop, :located_at, {nil, nil})

        %{
          id: Ecto.UUID.generate(),
          organization_id: organization.id,
          gtfs_version_id: version.id,
          stop_id: stop.stop_id,
          stop_name: Map.get(stop, :stop_name, "Stop #{stop.stop_id}"),
          location_type: Map.get(stop, :location_type, 0),
          zone_id: Map.get(stop, :zone_id),
          stop_lat: decimal(lat),
          stop_lon: decimal(lon),
          parent_station: Map.get(stop, :parent_station),
          platform_code: Map.get(stop, :platform_code),
          inserted_at: now,
          updated_at: now
        }
      end)

    {count, nil} = Repo.insert_all(Stop, rows)
    assert count == length(rows)
    rows
  end

  defp decimal(nil), do: nil
  defp decimal(value), do: Decimal.new(value)
end
