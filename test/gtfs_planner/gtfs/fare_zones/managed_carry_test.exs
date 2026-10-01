defmodule GtfsPlanner.Gtfs.FareZones.ManagedCarryTest do
  @moduledoc """
  Merge evidence (EV-23) for carrying a zone ID onto `fare_leg_rules` and
  refreshing a managed version's implied rows (AC-8, AC-24, R7, INV-1, INV-2,
  INV-4, FH-23).

  Every expected value is worked by hand from
  `test/fixtures/gtfs/fares/north_coast_v2` and the GTFS reference, never read
  back from the writer under test (CR-2):

  - `areas.txt` declares `NPT` "Newport local", `TOL` "Toledo and valley" and
    `CST` "Coast zone"; `stop_areas.txt` gives `NPT` the five stops `NTC`, `NYE`,
    `HOSP`, `AGATE` and `SBPR`, `TOL` the two `TOLEDO` and `SILETZ`, and `CST`
    the five `DEPOE`, `LCTC`, `WALDPORT`, `YACHATS` and `SEAL`.
  - the fixture's `fare_leg_rules.txt` holds 46 rows: nine `N_LOCAL` zone pairs
    - the same-zone trips `NPT`, `TOL` and `CST`, the valley pair `NPT`<->`TOL`,
    the coast pair `NPT`<->`CST` and the valley-coast pair `TOL`<->`CST` - with
    one row per rider category each, so 36 rows, then the four `N_INTERCITY`
    intercity rows, three `N_LOCAL` rows naming no area for the day pass and
    three rows naming no network for the 31-day pass.
  - R3's priority is `8·[from_timeframe] + 4·[network] + 2·[from_area] +
    1·[to_area]`, so a `N_LOCAL` rule naming two zones is 7, one naming a single
    zone 6, one naming only a network 4, one naming a pair in either direction 3
    and one naming nothing 0. A zone that moves under these rows changes those
    numbers, which is what makes a refreshed implied column observable rather
    than a copy of the row's input. R4's leg group is the rule's network, or
    `"all_routes"` when it names none.
  - R4's pass rows are one per condition set of the single rides whose leg group
    the pass accepts, so a `$9.00` "Weekend pass" accepting `N_LOCAL` has one row
    per `N_LOCAL` condition set and no other.

  The version enters rows through the production importer and the production v2
  conversion, the pass through `Fares.save_fare/2` as an operator creates one, and
  every zone write runs inside
  `GtfsPlanner.Gtfs.Fares.VersionLock.transact/3`, which is where
  `Fares.Normalize.run!/2` runs for a managed version (R7, INV-1).
  """
  use GtfsPlanner.DataCase, async: true

  import Ecto.Query
  import GtfsPlanner.AccountsFixtures, only: [user_fixture: 1]
  import GtfsPlanner.FaresFixtures, only: [import!: 3]
  import GtfsPlanner.OrganizationsFixtures, only: [organization_fixture: 1]
  import GtfsPlanner.VersionsFixtures, only: [gtfs_version_fixture: 2]

  alias GtfsPlanner.Gtfs.FareLegRule
  alias GtfsPlanner.Gtfs.FareRule
  alias GtfsPlanner.Gtfs.Fares
  alias GtfsPlanner.Gtfs.Fares.Conversion
  alias GtfsPlanner.Gtfs.FareZone
  alias GtfsPlanner.Gtfs.FareZones
  alias GtfsPlanner.Repo

  setup do
    organization =
      organization_fixture(%{alias: "fares-zones-carry-#{System.unique_integer([:positive])}"})

    # An explicit email: the smokes on this shared partition commit
    # `user-1@example.com`, and `System.unique_integer/1` restarts per BEAM.
    actor =
      user_fixture(%{
        email: "fares-zones-carry-#{System.unique_integer([:positive])}@example.com"
      })

    version = gtfs_version_fixture(organization.id, %{name: "North Coast zones"})
    import!(organization, version, "north_coast_v2")

    scope = scope(organization, version, actor)

    {:ok, plan} = Conversion.preview(organization.id, version.id)
    {:ok, _converted} = Conversion.apply(scope, plan.fingerprint, [])

    %{organization: organization, version: version, scope: scope}
  end

  describe "a rename on a managed version" do
    test "carries the trimmed ID onto every leg rule that names it", context do
      %{organization: organization, version: version} = context

      # The fixture's 46 rows, with `NPT` written `NEW` in every area column.
      assert leg_rule_count(organization, version) == 46

      assert {:ok, zone} =
               FareZones.update_zone(organization.id, version.id, "NPT", %{"zone_id" => " NEW "})

      assert zone.zone_id == "NEW"
      assert zone.name == "Newport local"
      assert zone.declared?
      assert zone.stop_count == 5
      assert zone.rule_count == 0

      # The five `NPT` stops of `stop_areas.txt` moved and no stop kept the old ID.
      assert stop_zone_ids(organization, version, "NEW") == [
               "AGATE",
               "HOSP",
               "NTC",
               "NYE",
               "SBPR"
             ]

      assert stop_zone_ids(organization, version, "NPT") == []

      # A carry, not a new set of rows: 46 in, 46 out, and none names `NPT`.
      assert leg_rule_count(organization, version) == 46
      assert areas_referencing(organization, version, "NPT") == []

      assert conditions(organization, version) == [
               {nil, nil, nil},
               {"N_INTERCITY", nil, nil},
               {"N_LOCAL", nil, nil},
               {"N_LOCAL", "CST", "CST"},
               {"N_LOCAL", "CST", "NEW"},
               {"N_LOCAL", "CST", "TOL"},
               {"N_LOCAL", "NEW", "CST"},
               {"N_LOCAL", "NEW", "NEW"},
               {"N_LOCAL", "NEW", "TOL"},
               {"N_LOCAL", "TOL", "CST"},
               {"N_LOCAL", "TOL", "NEW"},
               {"N_LOCAL", "TOL", "TOL"}
             ]

      # R7: every area a leg rule names is a zone the inventory carries, so
      # `areas.txt` holds one row per inventory zone and no orphan area.
      assert inventory_zone_ids(organization, version) == ["CST", "NEW", "TOL"]

      assert leg_rule_area_ids(organization, version) -- inventory_zone_ids(organization, version) ==
               []

      assert implied_columns_agree?(organization, version)
    end
  end

  describe "a delete with a replacement on a managed version" do
    test "carries the ID, drops rows that would duplicate another, and mirrors the pass",
         context do
      %{organization: organization, version: version} = context

      # A `$9.00` pass accepting `N_LOCAL`, created the way an operator creates
      # one: it leaves one row per `N_LOCAL` condition set, the nine zone pairs
      # and the no-area row.
      assert {:ok, _fare} =
               Fares.save_fare(context.scope, %{
                 name: "Weekend pass",
                 kind: "pass",
                 media_ids: ["cash"],
                 prices: %{"adult" => "9.00"},
                 accepted_network_ids: ["N_LOCAL"]
               })

      assert pass_conditions(organization, version) == [
               {"N_LOCAL", "CST", "CST"},
               {"N_LOCAL", "CST", "NPT"},
               {"N_LOCAL", "CST", "TOL"},
               {"N_LOCAL", "NPT", "CST"},
               {"N_LOCAL", "NPT", "NPT"},
               {"N_LOCAL", "NPT", "TOL"},
               {"N_LOCAL", "TOL", "CST"},
               {"N_LOCAL", "TOL", "NPT"},
               {"N_LOCAL", "TOL", "TOL"},
               {"N_LOCAL", nil, nil}
             ]

      # 46 rows from the fixture and 10 pass rows.
      assert leg_rule_count(organization, version) == 56

      assert {:ok, %{moved_stops: 2, rewritten_rows: 0, removed_duplicate_rows: 0}} =
               FareZones.delete_zone(organization.id, version.id, "TOL", "NPT", %{
                 stop_count: 2,
                 rule_count: 0
               })

      # The two `TOL` stops joined the five `NPT` stops and none kept the ID.
      assert stop_zone_ids(organization, version, "NPT") ==
               ["AGATE", "HOSP", "NTC", "NYE", "SBPR", "SILETZ", "TOLEDO"]

      assert areas_referencing(organization, version, "TOL") == []

      # `TOL,TOL` became `NPT,NPT`, which the same-zone trip already stated, and
      # `TOL,NPT` became the `NPT,NPT` the kept `NPT,TOL` row now states, so
      # those eight rows are dropped. `NPT,TOL`, `TOL,CST` and `CST,TOL` state
      # conditions no row held and are kept.
      assert conditions(organization, version) == [
               {nil, nil, nil},
               {"N_INTERCITY", nil, nil},
               {"N_LOCAL", nil, nil},
               {"N_LOCAL", "CST", "CST"},
               {"N_LOCAL", "CST", "NPT"},
               {"N_LOCAL", "NPT", "CST"},
               {"N_LOCAL", "NPT", "NPT"}
             ]

      # 46 - 8 dropped + 10 pass rows - 5 rebuilt pass rows.
      assert leg_rule_count(organization, version) == 43

      # R4: the pass mirrors exactly the condition sets of the single rides it
      # stands in for, and nothing else.
      assert pass_conditions(organization, version) == [
               {"N_LOCAL", "CST", "CST"},
               {"N_LOCAL", "CST", "NPT"},
               {"N_LOCAL", "NPT", "CST"},
               {"N_LOCAL", "NPT", "NPT"},
               {"N_LOCAL", nil, nil}
             ]

      # INV-4: only `Fares.Normalize` writes these, and it ran here. The valley
      # ride moved from a one-zone pair (priority 3) onto `NPT,NPT` (priority 7),
      # which the carry itself does not write.
      assert priority_of(organization, version, "valley_ride_adult_cash", "N_LOCAL", "NPT", "NPT") ==
               7

      assert priority_of(organization, version, "valley_ride_adult_cash", "N_LOCAL", "NPT", nil) ==
               nil

      assert implied_columns_agree?(organization, version)
    end
  end

  describe "a delete without a replacement on a managed version" do
    test "clears the area of every leg rule that named it and refreshes their priority",
         context do
      %{organization: organization, version: version} = context

      # No fare rule of this version names `CST`, so the zone is unreferenced and
      # the workspace may delete it without naming a replacement.
      assert {:ok, %{moved_stops: 5}} =
               FareZones.delete_zone(organization.id, version.id, "CST", nil, %{
                 stop_count: 5,
                 rule_count: 0
               })

      assert areas_referencing(organization, version, "CST") == []
      assert inventory_zone_ids(organization, version) == ["NPT", "TOL"]

      # A cleared area states no zone, so none of the rewritten rows lands on a
      # row that already stated it: every row survives and none keeps `CST`.
      assert leg_rule_count(organization, version) == 46

      # R3's numbers, worked by hand: `CST,CST` named two zones at 7 and now
      # names none at 4, `NPT,CST` and `TOL,CST` drop from 7 to 6, `CST,NPT` and
      # `CST,TOL` from 7 to 5, and the rows that never named `CST` keep theirs.
      assert priorities_by_conditions(organization, version) == [
               {{nil, nil, nil}, 0},
               {{nil, "NPT"}, 5},
               {{nil, "TOL"}, 5},
               {{"N_LOCAL", nil, nil}, 4},
               {{"N_LOCAL", "NPT", nil}, 6},
               {{"N_LOCAL", "NPT", "NPT"}, 7},
               {{"N_LOCAL", "NPT", "TOL"}, 3},
               {{"N_LOCAL", "TOL", nil}, 6},
               {{"N_LOCAL", "TOL", "NPT"}, 3},
               {{"N_LOCAL", "TOL", "TOL"}, 7},
               {{"N_INTERCITY", nil, nil}, 4}
             ]

      assert implied_columns_agree?(organization, version)
    end
  end

  describe "a rename on an unmanaged version" do
    test "carries the ID to the fare rules and leg rules and writes no implied row", context do
      %{organization: organization} = context

      version = gtfs_version_fixture(organization.id, %{name: "Unmanaged zones"})
      import!(organization, version, "north_coast_v2")

      # An imported version carries its areas in the feed's leg rules only, so a
      # zone record and a fare rule are what put `NPT` in its inventory.
      insert_zone_record(organization, version, "NPT", "Newport local")
      rule_id = insert_fare_rule(organization, version, "F-1", "NPT", "CST")

      assert {:ok, zone} =
               FareZones.update_zone(organization.id, version.id, "NPT", %{"zone_id" => "NEW"})

      assert zone == %{
               zone_id: "NEW",
               name: "Newport local",
               color: FareZone.default_color("NEW"),
               declared?: true,
               stop_count: 0,
               other_stop_count: 0,
               rule_count: 1
             }

      # The `fare_rules` carry of step 21 still runs on this path, and this
      # step's leg-rule carry joins it in the same transaction.
      assert fare_rule_zone(organization, version, rule_id) == {"NEW", "CST", nil}
      assert leg_rule_count(organization, version) == 46
      assert areas_referencing(organization, version, "NPT") == []

      # An unmanaged version has no implied rows, so the imported `LG_LOCAL` leg
      # groups, the three 31-day pass rows the feed gave no group, and the nil
      # priorities it carried are left exactly as they were:
      # `Fares.Normalize.run!/2` is a managed version's writer only.
      assert leg_group_ids(organization, version) |> Enum.frequencies() == %{
               "LG_INTERCITY" => 4,
               "LG_LOCAL" => 39,
               nil => 3
             }

      assert priorities(organization, version) |> Enum.frequencies() == %{nil => 46}
    end
  end

  defp scope(organization, version, actor) do
    %{
      organization_id: organization.id,
      gtfs_version_id: version.id,
      audit: %GtfsPlanner.Gtfs.AuditContext{
        organization_id: organization.id,
        gtfs_version_id: version.id,
        station_stop_id: nil,
        actor_id: actor.id,
        actor_email: actor.email
      }
    }
  end

  defp scoped_rules(organization, version) do
    from(r in FareLegRule,
      where: r.organization_id == ^organization.id and r.gtfs_version_id == ^version.id
    )
  end

  # The version holds a few dozen leg rules, so the tests read them once and
  # work the answers in Elixir rather than asking the database to shape each one.
  defp rules(organization, version) do
    organization |> scoped_rules(version) |> Repo.all()
  end

  defp leg_rule_count(organization, version) do
    organization |> scoped_rules(version) |> Repo.aggregate(:count)
  end

  defp conditions(organization, version) do
    rules(organization, version)
    |> Enum.map(&{&1.network_id, &1.from_area_id, &1.to_area_id})
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp priorities_by_conditions(organization, version) do
    rules(organization, version)
    |> Enum.map(&{&1.network_id, &1.from_area_id, &1.to_area_id, &1.rule_priority})
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.map(fn {network_id, from_area_id, to_area_id, rule_priority} ->
      {{network_id, from_area_id, to_area_id}, rule_priority}
    end)
  end

  defp areas_referencing(organization, version, zone_id) do
    rules(organization, version)
    |> Enum.filter(&(&1.from_area_id == zone_id or &1.to_area_id == zone_id))
    |> Enum.map(&{&1.from_area_id, &1.to_area_id})
    |> Enum.sort()
  end

  defp leg_rule_area_ids(organization, version) do
    rules(organization, version)
    |> Enum.flat_map(&[&1.from_area_id, &1.to_area_id])
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp pass_conditions(organization, version) do
    rules(organization, version)
    |> Enum.filter(&(&1.fare_product_id == "weekend_pass"))
    |> Enum.map(&{&1.network_id, &1.from_area_id, &1.to_area_id})
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp priority_of(organization, version, fare_product_id, network_id, from_area, to_area) do
    rules(organization, version)
    |> Enum.filter(
      &(&1.fare_product_id == fare_product_id and &1.network_id == network_id and
          &1.from_area_id == from_area and &1.to_area_id == to_area)
    )
    |> Enum.map(& &1.rule_priority)
    |> Enum.uniq()
    |> case do
      [priority] -> priority
      [] -> nil
    end
  end

  defp priorities(organization, version) do
    rules(organization, version) |> Enum.map(& &1.rule_priority)
  end

  defp leg_group_ids(organization, version) do
    rules(organization, version) |> Enum.map(& &1.leg_group_id)
  end

  defp inventory_zone_ids(organization, version) do
    organization.id
    |> FareZones.inventory(version.id)
    |> Map.fetch!(:zones)
    |> Enum.map(& &1.zone_id)
  end

  defp stop_zone_ids(organization, version, zone_id) do
    Repo.all(
      from(s in GtfsPlanner.Gtfs.Stop,
        where:
          s.organization_id == ^organization.id and s.gtfs_version_id == ^version.id and
            s.zone_id == ^zone_id,
        order_by: s.stop_id,
        select: s.stop_id
      )
    )
  end

  defp insert_zone_record(organization, version, zone_id, name) do
    %FareZone{
      organization_id: organization.id,
      gtfs_version_id: version.id,
      zone_id: zone_id,
      name: name,
      color: FareZone.default_color(zone_id)
    }
    |> FareZone.changeset(%{}, :keep)
    |> Repo.insert!()
  end

  defp insert_fare_rule(organization, version, fare_id, origin_id, destination_id) do
    %FareRule{
      organization_id: organization.id,
      gtfs_version_id: version.id,
      fare_id: fare_id,
      origin_id: origin_id,
      destination_id: destination_id
    }
    |> FareRule.changeset(%{})
    |> Repo.insert!()
    |> Map.fetch!(:id)
  end

  defp fare_rule_zone(organization, version, rule_id) do
    Repo.one(
      from(r in FareRule,
        where:
          r.organization_id == ^organization.id and r.gtfs_version_id == ^version.id and
            r.id == ^rule_id,
        select: {r.origin_id, r.destination_id, r.contains_id}
      )
    )
  end

  # R3's priority and R4's leg group, worked by hand rather than read from the
  # row: a zone that moved changes the numbers, so agreement is the proof that
  # `Fares.Normalize.run!/2` rewrote the implied columns.
  defp implied_columns_agree?(organization, version) do
    rules(organization, version)
    |> Enum.all?(fn rule ->
      rule.rule_priority ==
        expected_priority(
          rule.network_id,
          rule.from_area_id,
          rule.to_area_id,
          rule.from_timeframe_group_id
        ) and rule.leg_group_id == expected_leg_group(rule.network_id)
    end)
  end

  defp expected_priority(network, from_area, to_area, timeframe) do
    present(2, from_area) + present(1, to_area) + present(4, network) + present(8, timeframe)
  end

  defp present(_weight, nil), do: 0
  defp present(weight, _value), do: weight

  defp expected_leg_group(nil), do: "all_routes"
  defp expected_leg_group(network_id), do: network_id
end
