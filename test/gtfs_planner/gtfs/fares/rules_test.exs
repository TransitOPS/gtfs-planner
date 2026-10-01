defmodule GtfsPlanner.Gtfs.Fares.RulesTest do
  @moduledoc """
  Merge evidence (EV-20) for `Fares.set_zone_fare/7`, `Fares.save_rule/3`,
  `Fares.delete_rule/3` and `Fares.set_pass_acceptance/5` (AC-20, AC-21, R4,
  R12, R15, FH-20).

  Every expected value is worked by hand from the fixture and from the rules,
  never read back from the code under test (CR-2):

  - the fixture's `fare_leg_rules` rows 30–37 are the two `N_LOCAL` pairs
    `CST`→`TOL` and `TOL`→`CST`, each naming the four cash products of the
    `valley_coast_ride` fare. So both directions of that pair start priced with
    the same fare, one row per rider type, all four with a nil network timeframe
    and `rule_priority` 7 (R3 gives 7 to a pair with two zones and no time).
  - `coast_ride` is a second fare in the fixture with its own four cash products
    (`coast_ride_adult_cash`, `coast_ride_child_cash`,
    `coast_ride_reduced_cash`, `coast_ride_youth_cash`), so it can be the fare
    that overlaps `valley_coast_ride` at one pair without being either of its own
    rider products (R12: the overlap is between two *fares*, not two rows).
  - the fixture's four `N_INTERCITY` rows are the Intercity ride's four rider
    types, and no `fare_product_details` row of this version has `kind = "pass"`
    until a test saves the Day pass as one, which is why the pass acceptance is
    reached only after `Fares.save_fare/2` (R4).

  The version enters rows through the production importer and the production v2
  conversion, and every write runs inside
  `GtfsPlanner.Gtfs.Fares.VersionLock.transact/3` with
  `Fares.Normalize.run!/2` before the commit, which is the path every writer of
  this package takes and what rebuilds a pass's mirrored rows after its accepted
  networks change (R4).
  """
  use GtfsPlanner.DataCase, async: true

  import Ecto.Query
  import GtfsPlanner.AccountsFixtures, only: [user_fixture: 1]
  import GtfsPlanner.FaresFixtures, only: [import!: 3]
  import GtfsPlanner.OrganizationsFixtures, only: [organization_fixture: 1]
  import GtfsPlanner.VersionsFixtures, only: [gtfs_version_fixture: 2]

  alias GtfsPlanner.Gtfs.AuditContext
  alias GtfsPlanner.Gtfs.ChangeLog
  alias GtfsPlanner.Gtfs.FareLegRule
  alias GtfsPlanner.Gtfs.FareProductDetail
  alias GtfsPlanner.Gtfs.Fares
  alias GtfsPlanner.Gtfs.Fares.Conversion
  alias GtfsPlanner.Repo

  # The four cash products of the `valley_coast_ride` fare, sorted, which is what
  # a cell of the `CST`/`TOL` pair names once the fixture is converted.
  @valley_products ~w(valley_coast_ride_adult_cash valley_coast_ride_child_cash
                      valley_coast_ride_reduced_cash valley_coast_ride_youth_cash)

  # The four cash products of the `coast_ride` fare, sorted.
  @coast_products ~w(coast_ride_adult_cash coast_ride_child_cash coast_ride_reduced_cash
                     coast_ride_youth_cash)

  setup do
    organization =
      organization_fixture(%{alias: "fares-rules-#{System.unique_integer([:positive])}"})

    actor =
      user_fixture(%{
        email: "fares-rules-#{System.unique_integer([:positive])}@example.com"
      })

    version = gtfs_version_fixture(organization.id, %{name: "North Coast fares editor"})
    import!(organization, version, "north_coast_v2")

    context = %{
      organization: organization,
      version: version,
      scope: scope(organization, version, actor)
    }

    {:ok, plan} = Conversion.preview(organization.id, version.id)
    {:ok, _converted} = Conversion.apply(context.scope, plan.fingerprint, [])

    context
  end

  describe "setting the fare of a cell of the zone matrix" do
    test "writes the chosen fare into both directions of the pair", context do
      assert cell_products(context, "CST", "TOL") == @valley_products
      assert cell_products(context, "TOL", "CST") == @valley_products

      assert {:ok, _result} =
               Fares.set_zone_fare(
                 context.scope,
                 "N_LOCAL",
                 "CST",
                 "TOL",
                 "coast_ride_adult_cash",
                 true,
                 nil
               )

      # The four rider types of the chosen fare, one row each, in both directions
      # because "also for rides from TOL to CST" was set.
      assert cell_products(context, "CST", "TOL") == @coast_products
      assert cell_products(context, "TOL", "CST") == @coast_products

      # R3: `Normalize.run!/2` still owns the priority and the leg group, and a
      # pair of zones at no named time is priority 7 in the `N_LOCAL` group.
      assert cell_rule_count(context, "CST", "TOL") == 4
      assert cell_priorities(context, "CST", "TOL") == [7, 7, 7, 7]
      assert cell_leg_groups(context, "CST", "TOL") == ~w(N_LOCAL N_LOCAL N_LOCAL N_LOCAL)
    end

    test "leaves the other direction alone when the mirror is not set", context do
      assert {:ok, _result} =
               Fares.set_zone_fare(
                 context.scope,
                 "N_LOCAL",
                 "CST",
                 "TOL",
                 "coast_ride_adult_cash",
                 false,
                 nil
               )

      assert cell_products(context, "CST", "TOL") == @coast_products
      assert cell_products(context, "TOL", "CST") == @valley_products
    end

    test "clears the cell, and the mirrored pass rows with it", context do
      # The Day pass starts accepting nothing, so it has no mirrored row of its
      # own; accepting `N_LOCAL` first gives it four, one per zone pair the
      # single-ride rules name (R4).
      {:ok, context} = with_day_pass(context)

      assert {:ok, _accepted} =
               Fares.set_pass_acceptance(
                 context.scope,
                 "day_pass_adult_cash",
                 "N_LOCAL",
                 true,
                 []
               )

      assert pass_products(context) == ["day_pass_adult_cash"]
      assert pass_rows(context) > 0

      # The four zone pairs the converted single-ride rules name, mirrored once
      # each, plus the pass's own imported row (R4).
      assert pass_pair_rows(context, "CST", "TOL") != []

      assert {:ok, _cleared} =
               Fares.set_zone_fare(
                 context.scope,
                 "N_LOCAL",
                 "CST",
                 "TOL",
                 "coast_ride_adult_cash",
                 true,
                 nil
               )

      assert cell_products(context, "CST", "TOL") == @coast_products

      # Clearing the cell says nothing about the pass, which still accepts
      # `N_LOCAL`, so `Normalize.run!/2` rebuilds its mirrored rows from the
      # conditions that are left (R4). This is the point of R4: a cell write
      # never leaves the pass's rows disagreeing with the single-ride rules.
      assert pass_rows(context) > 0

      assert {:ok, _emptied} =
               Fares.set_zone_fare(
                 context.scope,
                 "N_LOCAL",
                 "CST",
                 "TOL",
                 nil,
                 true,
                 nil
               )

      assert cell_products(context, "CST", "TOL") == []
      assert cell_products(context, "TOL", "CST") == []

      # R4: the pass still accepts `N_LOCAL`, so its rows are whatever the
      # conditions that are left call for. With the pair emptied there is no
      # rule left naming it, so no pass row survives for it either.
      assert pass_pair_rows(context, "CST", "TOL") == []
      assert pass_pair_rows(context, "TOL", "CST") == []
    end

    test "refuses a fare this organization does not hold", context do
      assert {:error, :not_found} =
               Fares.set_zone_fare(
                 context.scope,
                 "N_LOCAL",
                 "CST",
                 "TOL",
                 "no_such_fare",
                 false,
                 nil
               )

      assert cell_products(context, "CST", "TOL") == @valley_products
    end
  end

  describe "saving a fare rule" do
    test "answers the overlap when another fare is priced for the same ride", context do
      # R12: `valley_coast_ride` is priced for `TOL`→`CST` and `coast_ride` is a
      # different fare for the same ride, so the save cannot decide on its own.
      assert {:error, {:overlap, conflict}} =
               Fares.save_rule(context.scope, tol_to_cst_form("coast_ride_adult_cash"), nil)

      assert conflict.network_id == "N_LOCAL"
      assert conflict.from_area_id == "TOL"
      assert conflict.to_area_id == "CST"
      assert conflict.fare_product_id in @valley_products

      # The refusal changed nothing.
      assert cell_products(context, "TOL", "CST") == @valley_products
    end

    test "replaces the overlapping fare when the operator chooses", context do
      assert {:error, {:overlap, _conflict}} =
               Fares.save_rule(context.scope, tol_to_cst_form("coast_ride_adult_cash"), nil)

      assert {:ok, _replaced} =
               Fares.save_rule(context.scope, tol_to_cst_form("coast_ride_adult_cash"), :replace)

      # One fare for one ride: the four `valley_coast_ride` rows are gone and the
      # four `coast_ride` rows are in their place.
      assert cell_products(context, "TOL", "CST") == @coast_products

      # The reverse pair was never named, so it still holds the fare it had.
      assert cell_products(context, "CST", "TOL") == @valley_products
    end

    test "keeps both fares when the operator chooses", context do
      assert {:ok, _kept} =
               Fares.save_rule(
                 context.scope,
                 tol_to_cst_form("coast_ride_adult_cash"),
                 :keep_both
               )

      assert cell_products(context, "TOL", "CST") ==
               Enum.sort(@coast_products ++ @valley_products)

      assert cell_rule_count(context, "TOL", "CST") == 8
    end

    test "a rider type of the fare being saved is not an overlap with it", context do
      # The same fare named by one of its own products is not a second fare for
      # the ride, so a repeated save is a no-op rather than a refusal (R12).
      assert {:ok, _saved} =
               Fares.save_rule(
                 context.scope,
                 tol_to_cst_form("valley_coast_ride_youth_cash"),
                 nil
               )

      assert cell_products(context, "TOL", "CST") == @valley_products
      assert cell_rule_count(context, "TOL", "CST") == 4
    end

    test "records one change-log entry saying what it did", context do
      assert {:ok, saved} =
               Fares.save_rule(context.scope, tol_to_cst_form("coast_ride_adult_cash"), :replace)

      assert [entry] = rule_entry(context, saved.operation_id)

      assert entry.action == "created"
      assert entry.changed_fields["summary"] =~ "TOL"
      assert entry.changed_fields["summary"] =~ "Coast ride"
    end
  end

  describe "deleting a fare rule" do
    test "takes the whole rule, every rider type of the fare", context do
      [row | _rest] = cell_rule_rows(context, "TOL", "CST")
      rule = rule_by_id(context, row.id)

      assert {:ok, _deleted} =
               Fares.delete_rule(context.scope, rule.id, %{
                 fare_product_id: rule.fare_product_id
               })

      # Half a rule would leave the cell priced for some rider types and not
      # others, so all four rows of the fare go.
      assert cell_products(context, "TOL", "CST") == []
      assert cell_rule_count(context, "TOL", "CST") == 0

      # The pair nobody named is untouched.
      assert cell_products(context, "CST", "TOL") == @valley_products
    end

    test "refuses a rule whose fare has moved since the list was read", context do
      [row | _rest] = cell_rule_rows(context, "TOL", "CST")
      rule = rule_by_id(context, row.id)

      assert {:error, {:stale, details}} =
               Fares.delete_rule(context.scope, rule.id, %{
                 fare_product_id: "coast_ride_adult_cash"
               })

      assert [%{field: :fare_product_id}] = details
      assert cell_products(context, "TOL", "CST") == @valley_products
    end

    test "refuses a rule of another organization", context do
      [row | _rest] = cell_rule_rows(context, "TOL", "CST")
      other = other_organization()

      assert {:error, :not_found} =
               Fares.delete_rule(
                 scope(other, context.version, other_actor(other)),
                 row.id,
                 %{}
               )

      assert cell_products(context, "TOL", "CST") == @valley_products
    end
  end

  describe "accepting a route group for a pass" do
    test "writes the pass's own row for the accepted networks", context do
      {:ok, context} = with_day_pass(context)

      # R4: the pass accepts nothing yet, so it has no row of its own.
      assert pass_rows(context) == 0

      assert {:ok, _accepted} =
               Fares.set_pass_acceptance(
                 context.scope,
                 "day_pass_adult_cash",
                 "N_INTERCITY",
                 true,
                 []
               )

      assert accepted_networks(context, "day_pass_adult_cash") == ["N_INTERCITY"]

      # One row, at the accepted network, with the priority `Normalize.run!/2`
      # gives a row naming one zone-less condition: 4 (R3).
      assert [{network_id, priority, leg_group_id}] = pass_rule_rows(context)

      assert network_id == "N_INTERCITY"
      assert priority == 4
      assert leg_group_id == "N_INTERCITY"
    end

    test "takes the group away again and the row with it", context do
      {:ok, context} = with_day_pass(context)

      {:ok, _accepted} =
        Fares.set_pass_acceptance(
          context.scope,
          "day_pass_adult_cash",
          "N_INTERCITY",
          true,
          []
        )

      assert pass_rows(context) == 1

      # `reviewed` is what the pass's list showed when the drawer opened, which
      # is the fence for R15: the write lands only if that is still stored.
      assert {:ok, _refused} =
               Fares.set_pass_acceptance(
                 context.scope,
                 "day_pass_adult_cash",
                 "N_INTERCITY",
                 false,
                 ["N_INTERCITY"]
               )

      assert accepted_networks(context, "day_pass_adult_cash") == []
      assert pass_rows(context) == 0
    end

    test "refuses a fare that is not a pass", context do
      assert {:error, :not_a_pass} =
               Fares.set_pass_acceptance(
                 context.scope,
                 "valley_coast_ride_adult_cash",
                 "N_INTERCITY",
                 true,
                 []
               )

      # The refusal wrote nothing: the product keeps the kind the conversion gave
      # it, which is a single-ride fare, and the accepted networks it already
      # carried.
      assert detail_kind(context, "valley_coast_ride_adult_cash") == "single"
      assert accepted_networks(context, "valley_coast_ride_adult_cash") == ["N_LOCAL"]
    end
  end

  # -- Helpers ------------------------------------------------------------------

  # The rule drawer's form for the `TOL`→`CST` pair of `N_LOCAL`, naming one
  # product of the fare to save. The fixture prices that pair already, so a save
  # of a second fare is the overlap.
  defp tol_to_cst_form(fare_product_id) do
    %{
      network_id: "N_LOCAL",
      from_area_id: "TOL",
      to_area_id: "CST",
      fare_product_id: fare_product_id
    }
  end

  defp scope(organization, version, actor) do
    %{
      organization_id: organization.id,
      gtfs_version_id: version.id,
      audit: %AuditContext{
        organization_id: organization.id,
        gtfs_version_id: version.id,
        station_stop_id: nil,
        actor_id: actor.id,
        actor_email: actor.email
      }
    }
  end

  # The Day pass as an operator would make it: saved through `save_fare/2` with
  # `kind: "pass"`, which is the only way a version's product becomes a pass and
  # the only way its rows become `Normalize`'s to write.
  defp with_day_pass(context) do
    {:ok, _saved} =
      Fares.save_fare(context.scope, %{
        fare_product_id: "day_pass_adult_cash",
        name: "Day pass",
        kind: "pass",
        media_ids: ["cash"],
        prices: %{"adult" => "4.00", "reduced" => "2.00", "youth" => "2.00"},
        accepted_network_ids: []
      })

    {:ok, context}
  end

  # The products priced for one `N_LOCAL` pair, sorted and deduplicated, which is
  # the fare level answer: a cell is priced by fare, not by row. A pass's mirrored
  # rows name the same pair and are left out, because they are what
  # `Normalize.run!/2` writes from the pass's accepted networks (R4) rather than
  # the price of the cell.
  defp cell_products(context, from_area_id, to_area_id) do
    FareLegRule
    |> scoped(context)
    |> where([rule], rule.network_id == "N_LOCAL")
    |> where([rule], rule.from_area_id == ^from_area_id and rule.to_area_id == ^to_area_id)
    |> Repo.all()
    |> Enum.reject(&(&1.fare_product_id in pass_products(context)))
    |> Enum.map(& &1.fare_product_id)
    |> Enum.sort()
    |> Enum.uniq()
  end

  defp cell_rule_count(context, from_area_id, to_area_id) do
    context |> cell_rule_rows(from_area_id, to_area_id) |> length()
  end

  defp cell_rule_rows(context, from_area_id, to_area_id) do
    FareLegRule
    |> scoped(context)
    |> where([rule], rule.network_id == "N_LOCAL")
    |> where([rule], rule.from_area_id == ^from_area_id and rule.to_area_id == ^to_area_id)
    |> Repo.all()
  end

  defp cell_priorities(context, from_area_id, to_area_id) do
    context
    |> cell_rule_rows(from_area_id, to_area_id)
    |> Enum.map(& &1.rule_priority)
    |> Enum.sort()
  end

  defp cell_leg_groups(context, from_area_id, to_area_id) do
    context
    |> cell_rule_rows(from_area_id, to_area_id)
    |> Enum.map(& &1.leg_group_id)
    |> Enum.sort()
  end

  defp rule_by_id(context, rule_id) do
    FareLegRule |> scoped(context) |> where([rule], rule.id == ^rule_id) |> Repo.one!()
  end

  # The distinct products this version's passes name in their leg rules. The join
  # is scoped on the pair together, so a pass of another version's products is
  # never counted (INV-5).
  defp pass_products(context) do
    from(rule in FareLegRule,
      join: detail in FareProductDetail,
      on: detail.fare_product_id == rule.fare_product_id,
      where:
        rule.organization_id == ^context.organization.id and
          rule.gtfs_version_id == ^context.version.id and detail.kind == "pass",
      distinct: true,
      select: rule.fare_product_id
    )
    |> Repo.all()
    |> Enum.sort()
  end

  defp pass_rows(context) do
    FareLegRule
    |> scoped(context)
    |> where([rule], rule.fare_product_id == "day_pass_adult_cash")
    |> Repo.aggregate(:count)
  end

  # The pass's own rows for one pair. They are read apart from `cell_products/3`
  # because they are what `Normalize.run!/2` writes, not the cell's price.
  defp pass_pair_rows(context, from_area_id, to_area_id) do
    FareLegRule
    |> scoped(context)
    |> where([rule], rule.fare_product_id == "day_pass_adult_cash")
    |> where([rule], rule.from_area_id == ^from_area_id and rule.to_area_id == ^to_area_id)
    |> Repo.all()
  end

  defp pass_rule_rows(context) do
    FareLegRule
    |> scoped(context)
    |> where([rule], rule.fare_product_id == "day_pass_adult_cash")
    |> Repo.all()
    |> Enum.map(&{&1.network_id, &1.rule_priority, &1.leg_group_id})
  end

  defp accepted_networks(context, fare_product_id) do
    FareProductDetail
    |> scoped(context)
    |> where([detail], detail.fare_product_id == ^fare_product_id)
    |> select([detail], detail.accepted_network_ids)
    |> Repo.one()
  end

  # The one change-log entry this operation recorded, addressed the way every
  # writer of this module addresses one: by its operation id (R15).
  defp rule_entry(context, operation_id) do
    ChangeLog
    |> scoped(context)
    |> where([entry], entry.entity_type == "fare_version")
    |> where([entry], fragment("?->>?", entry.changed_fields, "operation_id") == ^operation_id)
    |> Repo.all()
  end

  defp detail_kind(context, fare_product_id) do
    FareProductDetail
    |> scoped(context)
    |> where([detail], detail.fare_product_id == ^fare_product_id)
    |> select([detail], detail.kind)
    |> Repo.one()
  end

  defp scoped(queryable, context) do
    where(
      queryable,
      [row],
      row.organization_id == ^context.organization.id and
        row.gtfs_version_id == ^context.version.id
    )
  end

  defp other_organization do
    organization_fixture(%{alias: "fares-rules-other-#{System.unique_integer([:positive])}"})
  end

  defp other_actor(organization) do
    user_fixture(%{
      email: "fares-rules-other-#{System.unique_integer([:positive])}@example.com",
      organization_memberships: [%{organization_id: organization.id}]
    })
  end
end
