defmodule GtfsPlanner.Gtfs.FareZones.RuleProjectionTest do
  @moduledoc """
  Merge evidence (EV-3) for the rule projection. One row maps to exactly one rule
  group, duplicates included, and every expected group below is a hand-written
  literal, so the projection cannot confirm its own output.

  - Nil and present `contains_id` rows of one journey form two groups.
  - Two exact duplicate rows form one group listing both rows.
  - The groups together hold every row of the version exactly once.
  - A missing fare and a missing non-nil route are flagged; a nil route is not.
  - A second version and a second organization with identical IDs contribute
    nothing, including their fare and route rows.
  """
  use GtfsPlanner.DataCase, async: true

  alias GtfsPlanner.Gtfs.FareAttribute
  alias GtfsPlanner.Gtfs.FareRule
  alias GtfsPlanner.Gtfs.FareZones
  alias GtfsPlanner.Gtfs.Route
  alias GtfsPlanner.OrganizationsFixtures
  alias GtfsPlanner.Repo
  alias GtfsPlanner.VersionsFixtures

  setup do
    organization = OrganizationsFixtures.organization_fixture()
    version = VersionsFixtures.gtfs_version_fixture(organization.id)

    %{organization: organization, version: version}
  end

  test "splits nil and present contains rows of one journey into two groups", %{
    organization: organization,
    version: version
  } do
    [journey_row, through_c, through_d] =
      insert_rules(organization, version, [
        {"F", nil, "A", "B", nil},
        {"F", nil, "A", "B", "C"},
        {"F", nil, "A", "B", "D"}
      ])

    assert [journey, through] = FareZones.list_rule_groups(organization.id, version.id)

    assert journey.key == {"F", nil, "A", "B", false}
    assert journey.contains == []
    assert Enum.map(journey.rows, & &1.id) == [journey_row.id]

    assert through.key == {"F", nil, "A", "B", true}
    assert through.contains == ["C", "D"]
    assert Enum.map(through.rows, & &1.id) == Enum.sort([through_c.id, through_d.id])
  end

  test "keeps two exact duplicate rows in one group listing both rows", %{
    organization: organization,
    version: version
  } do
    [first, second] =
      insert_rules(organization, version, [
        {"F", nil, "A", nil, nil},
        {"F", nil, "A", nil, nil}
      ])

    assert [group] = FareZones.list_rule_groups(organization.id, version.id)

    assert group.key == {"F", nil, "A", nil, false}
    assert group.contains == []
    assert Enum.map(group.rows, & &1.id) == Enum.sort([first.id, second.id])
  end

  test "assigns every row of the version to exactly one group", %{
    organization: organization,
    version: version
  } do
    inserted =
      insert_rules(organization, version, [
        {"F1", nil, "A", "B", nil},
        {"F1", nil, "A", "B", "C"},
        {"F1", nil, "A", "B", "C"},
        {"F2", "R1", nil, nil, nil}
      ])

    groups = FareZones.list_rule_groups(organization.id, version.id)
    row_ids = Enum.flat_map(groups, fn group -> Enum.map(group.rows, & &1.id) end)

    assert length(groups) == 3
    assert length(row_ids) == 4
    assert length(Enum.uniq(row_ids)) == length(row_ids)
    assert Enum.sort(row_ids) == Enum.sort(Enum.map(inserted, & &1.id))

    version_row_count =
      Repo.aggregate(
        from(r in FareRule,
          where: r.organization_id == ^organization.id and r.gtfs_version_id == ^version.id
        ),
        :count
      )

    assert version_row_count == length(row_ids)
  end

  test "resolves a known fare and flags a fare with no fare_attributes row", %{
    organization: organization,
    version: version
  } do
    insert_rules(organization, version, [
      {"KNOWN", nil, "A", nil, nil},
      {"MISSING", nil, "B", nil, nil}
    ])

    insert_fare(organization, version, "KNOWN", "2.50")

    assert [known, missing] = FareZones.list_rule_groups(organization.id, version.id)

    assert known.unknown_fare? == false
    assert known.fare.currency_type == "USD"
    assert Decimal.equal?(known.fare.price, Decimal.new("2.50"))

    assert missing.unknown_fare? == true
    assert missing.fare == nil
  end

  test "resolves a known route, flags a missing one and leaves a nil route unflagged", %{
    organization: organization,
    version: version
  } do
    insert_rules(organization, version, [
      {"F1", "R1", nil, nil, nil},
      {"F2", "MISSING", nil, nil, nil},
      {"F3", nil, nil, nil, nil}
    ])

    insert_route(organization, version, "R1", "1", "Downtown")

    assert [known, missing, no_route] = FareZones.list_rule_groups(organization.id, version.id)

    assert known.unknown_route? == false
    assert known.route == %{short_name: "1", long_name: "Downtown"}

    assert missing.unknown_route? == true
    assert missing.route == nil

    assert no_route.unknown_route? == false
    assert no_route.route == nil
  end

  test "orders groups by fare, journey, route and contains presence", %{
    organization: organization,
    version: version
  } do
    insert_rules(organization, version, [
      {"F1", "R1", "A", "B", nil},
      {"F1", nil, "A", "B", "C"},
      {"F1", nil, "B", "A", nil},
      {"F1", nil, "A", "B", nil},
      {"F0", nil, "A", "B", nil}
    ])

    keys =
      FareZones.list_rule_groups(organization.id, version.id)
      |> Enum.map(& &1.key)

    assert keys == [
             {"F0", nil, "A", "B", false},
             {"F1", nil, "A", "B", false},
             {"F1", nil, "A", "B", true},
             {"F1", "R1", "A", "B", false},
             {"F1", nil, "B", "A", false}
           ]
  end

  test "ignores a second version and a second organization with identical IDs", %{
    organization: organization,
    version: version
  } do
    other_version = VersionsFixtures.gtfs_version_fixture(organization.id)
    other_organization = OrganizationsFixtures.organization_fixture()
    other_organization_version = VersionsFixtures.gtfs_version_fixture(other_organization.id)

    [row] = insert_rules(organization, version, [{"F", "R1", "A", "B", nil}])
    insert_fare(organization, version, "F", "1.00")
    insert_route(organization, version, "R1", "1", "Local")

    insert_rules(organization, other_version, [{"F", "R1", "A", "B", nil}])
    insert_fare(organization, other_version, "F", "9.99")
    insert_route(organization, other_version, "R1", "9", "Other")

    insert_rules(other_organization, other_organization_version, [{"F", "R1", "A", "B", nil}])
    insert_fare(other_organization, other_organization_version, "F", "9.99")
    insert_route(other_organization, other_organization_version, "R1", "9", "Other")

    assert [group] = FareZones.list_rule_groups(organization.id, version.id)
    assert Enum.map(group.rows, & &1.id) == [row.id]
    assert Decimal.equal?(group.fare.price, Decimal.new("1.00"))
    assert group.route == %{short_name: "1", long_name: "Local"}

    assert FareZones.list_rule_groups(other_organization.id, version.id) == []
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

  defp insert_fare(organization, version, fare_id, price) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    {1, nil} =
      Repo.insert_all(FareAttribute, [
        %{
          id: Ecto.UUID.generate(),
          organization_id: organization.id,
          gtfs_version_id: version.id,
          fare_id: fare_id,
          price: Decimal.new(price),
          currency_type: "USD",
          payment_method: 0,
          inserted_at: now,
          updated_at: now
        }
      ])
  end

  defp insert_route(organization, version, route_id, short_name, long_name) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    {1, nil} =
      Repo.insert_all(Route, [
        %{
          id: Ecto.UUID.generate(),
          organization_id: organization.id,
          gtfs_version_id: version.id,
          route_id: route_id,
          route_type: 3,
          route_short_name: short_name,
          route_long_name: long_name,
          inserted_at: now,
          updated_at: now
        }
      ])
  end
end
