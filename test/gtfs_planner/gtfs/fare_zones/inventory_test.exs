defmodule GtfsPlanner.Gtfs.FareZones.InventoryTest do
  @moduledoc """
  Merge evidence (EV-4) for the zone inventory, checks and names.

  The inventory is the byte-for-byte union of declared `fare_zones` records, stop
  zone IDs of every location type and fare-rule references, with boardable-only
  stop counts. Every expected value below is a hand-written literal or an
  independent `FareZone.default_color/1` call, so the queries cannot confirm
  their own output.

  - A declared zone with no stops or rules is empty, not stopless-referenced.
  - `" A"` and `"A"` are separate zones with their own boardable counts.
  - A station-only zone has no stops and one other location type.
  - A rule's duplicate rows and a repeated reference count once; a rule-only zone
    is stopless-referenced and turns on the rules-reference flag.
  - A declared record's name and color override the ID and palette defaults.
  - `boardable_count` and `unassigned_count` ignore stations, entrances and other
    location types.
  - A second organization and a second version with identical IDs contribute
    nothing, including their zone names.
  - `zone_names/3` returns declared names and exact IDs for undeclared zones.
  """
  use GtfsPlanner.DataCase, async: true

  alias GtfsPlanner.Gtfs.FareRule
  alias GtfsPlanner.Gtfs.FareZone
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

  test "lists a declared zone with no stops or rules as an empty declared zone", %{
    organization: organization,
    version: version
  } do
    insert_fare_zone(organization, version, "D", "Downtown", "plum")

    inventory = FareZones.inventory(organization.id, version.id)

    assert inventory.boardable_count == 0
    assert inventory.unassigned_count == 0

    assert [zone] = inventory.zones

    assert zone == %{
             zone_id: "D",
             name: "Downtown",
             color: "plum",
             declared?: true,
             stop_count: 0,
             other_stop_count: 0,
             rule_count: 0
           }

    checks = FareZones.checks(organization.id, version.id)

    assert Enum.map(checks.empty_declared, & &1.zone_id) == ["D"]
    assert checks.stopless_referenced == []
    assert checks.rules_reference_zones? == false
    assert checks.unassigned_count == 0
  end

  test "lists the padded and plain zone IDs as separate zones with their own counts", %{
    organization: organization,
    version: version
  } do
    insert_stops(organization, version, [
      {"s1", 0, "A"},
      {"s2", 0, "A"},
      {"s3", 0, " A"},
      {"s4", 0, nil}
    ])

    inventory = FareZones.inventory(organization.id, version.id)

    assert Enum.map(inventory.zones, & &1.zone_id) == [" A", "A"]
    assert [space, plain] = inventory.zones

    assert space.name == " A"
    assert space.declared? == false
    assert space.color == FareZone.default_color(" A")
    assert space.stop_count == 1
    assert space.other_stop_count == 0
    assert space.rule_count == 0

    assert plain.name == "A"
    assert plain.declared? == false
    assert plain.color == FareZone.default_color("A")
    assert plain.stop_count == 2
    assert plain.other_stop_count == 0

    palette_keys = Enum.map(FareZone.palette(), &elem(&1, 0))
    assert space.color in palette_keys
    assert plain.color in palette_keys

    assert inventory.boardable_count == 4
    assert inventory.unassigned_count == 1
  end

  test "counts a zone carried only by a station as a non-boardable zone", %{
    organization: organization,
    version: version
  } do
    insert_stops(organization, version, [{"st-1", 1, "S"}])

    inventory = FareZones.inventory(organization.id, version.id)

    assert [zone] = inventory.zones
    assert zone.zone_id == "S"
    assert zone.declared? == false
    assert zone.stop_count == 0
    assert zone.other_stop_count == 1

    assert inventory.boardable_count == 0
    assert inventory.unassigned_count == 0
  end

  test "counts a rule once per group despite duplicate rows and repeated references", %{
    organization: organization,
    version: version
  } do
    insert_stops(organization, version, [
      {"p-1", 0, "A"},
      {"p-2", 0, "B"}
    ])

    insert_rules(organization, version, [
      {"F1", nil, "A", "B", nil},
      {"F1", nil, "A", "B", nil},
      {"F2", nil, "A", "C", "A"}
    ])

    inventory = FareZones.inventory(organization.id, version.id)
    zones = Map.new(inventory.zones, &{&1.zone_id, &1})

    assert Enum.sort(Map.keys(zones)) == ["A", "B", "C"]

    # A is the origin of one group and the origin *and* contains of another, so two
    # groups reference it; counting rows would report three.
    assert zones["A"].rule_count == 2
    assert zones["A"].stop_count == 1
    assert zones["B"].rule_count == 1
    assert zones["B"].stop_count == 1
    assert zones["C"].rule_count == 1
    assert zones["C"].stop_count == 0

    checks = FareZones.checks(organization.id, version.id)

    assert Enum.map(checks.stopless_referenced, & &1.zone_id) == ["C"]
    assert checks.rules_reference_zones? == true
    assert checks.empty_declared == []
  end

  test "lets a declared record's name and color override the defaults", %{
    organization: organization,
    version: version
  } do
    insert_stops(organization, version, [{"p-1", 0, "A"}])
    insert_fare_zone(organization, version, "A", "Downtown core", "ochre")

    assert [zone] = FareZones.inventory(organization.id, version.id).zones

    assert zone.zone_id == "A"
    assert zone.name == "Downtown core"
    assert zone.color == "ochre"
    assert zone.declared? == true
    assert zone.stop_count == 1
  end

  test "counts only boardable stops in boardable_count and unassigned_count", %{
    organization: organization,
    version: version
  } do
    insert_stops(organization, version, [
      {"b-1", 0, "A"},
      {"b-2", 0, nil},
      {"st-1", 1, "A"},
      {"en-1", 2, nil},
      {"node-1", 3, "A"}
    ])

    inventory = FareZones.inventory(organization.id, version.id)

    assert inventory.boardable_count == 2
    assert inventory.unassigned_count == 1

    assert [zone] = inventory.zones
    assert zone.zone_id == "A"
    assert zone.stop_count == 1
    assert zone.other_stop_count == 2
  end

  test "classifies declared zones as empty, rule-referenced or neither", %{
    organization: organization,
    version: version
  } do
    insert_fare_zone(organization, version, "EMPTY", "No members", "green")
    insert_fare_zone(organization, version, "USED", "Rule only", "ocean")
    insert_fare_zone(organization, version, "STOPPED", "Has a stop", "teal")
    insert_stops(organization, version, [{"p-1", 0, "STOPPED"}])
    insert_rules(organization, version, [{"F", nil, "USED", nil, nil}])

    checks = FareZones.checks(organization.id, version.id)

    assert Enum.map(checks.empty_declared, & &1.zone_id) == ["EMPTY"]
    assert Enum.map(checks.stopless_referenced, & &1.zone_id) == ["USED"]
    assert checks.rules_reference_zones? == true
  end

  test "ignores a second version and a second organization with identical IDs", %{
    organization: organization,
    version: version
  } do
    other_version = VersionsFixtures.gtfs_version_fixture(organization.id)
    other_organization = OrganizationsFixtures.organization_fixture()
    other_organization_version = VersionsFixtures.gtfs_version_fixture(other_organization.id)

    insert_stops(organization, version, [{"p-1", 0, "A"}, {"p-2", 0, nil}])
    insert_fare_zone(organization, version, "A", "Main", "ocean")
    insert_rules(organization, version, [{"F", nil, "A", nil, nil}])

    insert_stops(organization, other_version, [{"p-1", 0, "A"}, {"p-9", 0, "Z"}])
    insert_fare_zone(organization, other_version, "A", "Other version", "plum")
    insert_fare_zone(organization, other_version, "Z", "Hidden", "green")
    insert_rules(organization, other_version, [{"F", nil, "A", nil, nil}])

    insert_stops(other_organization, other_organization_version, [{"p-1", 0, "A"}])
    insert_fare_zone(other_organization, other_organization_version, "A", "Foreign", "teal")
    insert_rules(other_organization, other_organization_version, [{"F", nil, "A", nil, nil}])

    inventory = FareZones.inventory(organization.id, version.id)

    assert Enum.map(inventory.zones, & &1.zone_id) == ["A"]
    assert inventory.boardable_count == 2
    assert inventory.unassigned_count == 1

    assert [zone] = inventory.zones
    assert zone.name == "Main"
    assert zone.color == "ocean"
    assert zone.stop_count == 1
    assert zone.other_stop_count == 0
    assert zone.rule_count == 1

    checks = FareZones.checks(organization.id, version.id)
    assert checks.rules_reference_zones? == true
    assert checks.empty_declared == []

    empty = %{zones: [], unassigned_count: 0, boardable_count: 0}
    assert FareZones.inventory(other_organization.id, version.id) == empty

    assert FareZones.checks(other_organization.id, version.id).rules_reference_zones? == false

    assert FareZones.zone_names(organization.id, version.id, ["A"]) == %{"A" => "Main"}

    assert FareZones.zone_names(organization.id, other_version.id, ["A"]) ==
             %{"A" => "Other version"}

    assert FareZones.zone_names(other_organization.id, version.id, ["A"]) == %{"A" => "A"}
  end

  test "resolves declared names and exact IDs for undeclared zones", %{
    organization: organization,
    version: version
  } do
    insert_fare_zone(organization, version, "A", "Downtown", "teal")
    insert_fare_zone(organization, version, " A", "Arrivals", "plum")

    assert FareZones.zone_names(organization.id, version.id, []) == %{}

    assert FareZones.zone_names(organization.id, version.id, ["A", " A", "Missing"]) == %{
             "A" => "Downtown",
             " A" => "Arrivals",
             "Missing" => "Missing"
           }
  end

  defp insert_stops(organization, version, stops) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    rows =
      Enum.map(stops, fn {stop_id, location_type, zone_id} ->
        %{
          id: Ecto.UUID.generate(),
          organization_id: organization.id,
          gtfs_version_id: version.id,
          stop_id: stop_id,
          stop_name: "Stop #{stop_id}",
          location_type: location_type,
          zone_id: zone_id,
          inserted_at: now,
          updated_at: now
        }
      end)

    {count, nil} = Repo.insert_all(Stop, rows)
    assert count == length(rows)
    rows
  end

  defp insert_fare_zone(organization, version, zone_id, name, color) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    {1, nil} =
      Repo.insert_all(FareZone, [
        %{
          id: Ecto.UUID.generate(),
          organization_id: organization.id,
          gtfs_version_id: version.id,
          zone_id: zone_id,
          name: name,
          color: color,
          inserted_at: now,
          updated_at: now
        }
      ])
  end

  defp insert_rules(organization, version, attrs_list) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    rows =
      Enum.map(attrs_list, fn {fare_id, route_id, origin_id, destination_id, contains_id} ->
        %{
          id: Ecto.UUID.generate(),
          organization_id: organization.id,
          gtfs_version_id: version.id,
          fare_id: fare_id,
          route_id: route_id,
          origin_id: origin_id,
          destination_id: destination_id,
          contains_id: contains_id,
          inserted_at: now,
          updated_at: now
        }
      end)

    {count, nil} = Repo.insert_all(FareRule, rows)
    assert count == length(rows)
    rows
  end
end
