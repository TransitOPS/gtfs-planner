defmodule GtfsPlanner.Gtfs.Fares.NormalizeTest do
  @moduledoc """
  Merge evidence (EV-10) for `Fares.Normalize.run!/2`, the one writer of a managed
  version's implied fare rows (R3–R5, R8; AC-7, AC-8, AC-9).

  Every expected value is worked by hand from the North Coast v2 fixture in
  `test/fixtures/gtfs/fares/north_coast_v2` and from R3–R5, not read back from
  the code under test: the priority formula is written out again in this file,
  the nine accepted zone pairs are the three zones of `areas.txt` in both
  directions, and the counts are literals.

  Each case runs the function the way a writer runs it — inside
  `Fares.VersionLock.transact/2` — so the membership and version-row locks and the rollback case
  are the production path.
  """
  use GtfsPlanner.DataCase, async: true

  import GtfsPlanner.AccountsFixtures, only: [editor_fixture: 1]
  import Ecto.Query
  import GtfsPlanner.FaresFixtures, only: [import!: 3]
  import GtfsPlanner.OrganizationsFixtures, only: [organization_fixture: 1]
  import GtfsPlanner.VersionsFixtures, only: [gtfs_version_fixture: 1]

  alias GtfsPlanner.Gtfs.FareLegRule
  alias GtfsPlanner.Gtfs.AuditContext
  alias GtfsPlanner.Gtfs.FareProductDetail
  alias GtfsPlanner.Gtfs.Fares.InvariantError
  alias GtfsPlanner.Gtfs.Fares.Normalize
  alias GtfsPlanner.Gtfs.Fares.VersionLock
  alias GtfsPlanner.Gtfs.FareTransferRule
  alias GtfsPlanner.Gtfs.FareVersionSetting
  alias GtfsPlanner.Gtfs.RiderCategory

  # R3's example row: an Intercity rule whose departure is the weekday peak.
  @peak_product "intercity_ride_adult_cash"

  setup do
    organization = organization_fixture(%{alias: alias()})
    editor = editor_fixture(organization)
    version = gtfs_version_fixture(organization.id)

    import!(organization, version, "north_coast_v2")
    mark_managed!(organization.id, version.id)
    record_product_kinds!(organization.id, version.id)

    context = %{
      organization_id: organization.id,
      gtfs_version_id: version.id,
      organization: organization,
      version: version,
      scope: %{
        organization_id: organization.id,
        gtfs_version_id: version.id,
        audit: %AuditContext{
          organization_id: organization.id,
          gtfs_version_id: version.id,
          station_stop_id: nil,
          actor_id: editor.id,
          actor_email: editor.email
        }
      }
    }

    add_peak_rule!(context)
    insert_rule!(context, "local_ride_adult_cash", nil, nil, nil, nil)

    context
  end

  describe "R3 — priorities and leg groups" do
    test "every leg rule carries the R3 priority, a nil to_timeframe and its leg group",
         context do
      normalize!(context)

      for rule <- rules(context) do
        assert rule.rule_priority == r3_priority(rule),
               "#{inspect(rule.fare_product_id)} at #{rule.network_id}/#{rule.from_area_id}/" <>
                 "#{rule.to_area_id}/#{rule.from_timeframe_group_id} should have priority " <>
                 "#{r3_priority(rule)}, stored #{inspect(rule.rule_priority)}"

        assert is_nil(rule.to_timeframe_group_id)
        assert rule.leg_group_id == leg_group(rule)
      end
    end

    test "the priority of the fixture's own rows is 7 on a local zone rule and 4 on Intercity",
         context do
      normalize!(context)

      assert priority_of(context, "local_ride_adult_cash", "N_LOCAL", "NPT", "NPT", nil) == 7
      assert priority_of(context, "valley_ride_adult_cash", "N_LOCAL", "NPT", "TOL", nil) == 7
      assert priority_of(context, "coast_ride_adult_cash", "N_LOCAL", "NPT", "CST", nil) == 7
      assert priority_of(context, "intercity_ride_adult_cash", "N_INTERCITY", nil, nil, nil) == 4
    end

    test "an Intercity rule for the weekday peak has priority 12", context do
      normalize!(context)

      assert priority_of(context, @peak_product, "N_INTERCITY", nil, nil, "weekday_peak") == 12
      assert priority_of(context, @peak_product, "N_INTERCITY", nil, nil, nil) == 4
    end

    test "a rule with no network is the all_routes leg group", context do
      normalize!(context)

      assert %FareLegRule{network_id: nil, leg_group_id: "all_routes"} =
               rule(context, "local_ride_adult_cash", nil, nil, nil, nil)
    end

    test "the rows of another version are untouched", context do
      other_version = gtfs_version_fixture(context.organization_id)
      import!(context.organization, other_version, "north_coast_v2")
      other = %{context | gtfs_version_id: other_version.id}

      before = rules(other)

      normalize!(context)

      assert rules(other) == before
      assert Enum.all?(rules(other), &is_nil(&1.rule_priority))
      # The other version's imported pass rows are still stored: only the
      # normalized version has its pass rows rebuilt.
      assert length(rules(other)) == length(before)
      assert Enum.any?(rules(other), &(&1.fare_product_id == "day_pass_reduced_cash"))
    end
  end

  describe "R4 — pass rows" do
    test "a Day pass accepted on local gets exactly nine rows at priority 7", context do
      normalize!(context)

      pass_rows = pass_rows(context, "day_pass_adult_cash")

      assert length(pass_rows) == 9
      assert Enum.all?(pass_rows, &(&1.rule_priority == 7))
      assert Enum.all?(pass_rows, &(&1.network_id == "N_LOCAL"))
      assert Enum.all?(pass_rows, &(&1.leg_group_id == "N_LOCAL"))
      assert Enum.all?(pass_rows, &is_nil(&1.to_timeframe_group_id))

      assert Enum.sort(Enum.map(pass_rows, &{&1.from_area_id, &1.to_area_id})) ==
               Enum.sort(nine_zone_pairs())
    end

    test "a pass row states the same conditions as the single-ride rows of its cell", context do
      normalize!(context)

      for {from_area_id, to_area_id} <- nine_zone_pairs() do
        # The fixture names one single-ride product per zone pair, and it is not
        # always the Local ride: the coast and valley pairs name their own.
        single =
          context
          |> rules()
          |> Enum.filter(
            &(&1.network_id == "N_LOCAL" and &1.from_area_id == from_area_id and
                &1.to_area_id == to_area_id and
                &1.fare_product_id != "day_pass_adult_cash")
          )

        assert length(single) == 4
        assert Enum.uniq(Enum.map(single, & &1.rule_priority)) == [7]

        pass =
          Enum.find(pass_rows(context, "day_pass_adult_cash"), fn row ->
            row.from_area_id == from_area_id and row.to_area_id == to_area_id
          end)

        for single_rule <- single do
          assert pass.rule_priority == single_rule.rule_priority
          assert pass.network_id == single_rule.network_id
          assert pass.from_timeframe_group_id == single_rule.from_timeframe_group_id
        end
      end
    end

    test "withdrawing the acceptance removes the pass rows on the next run", context do
      normalize!(context)

      assert length(pass_rows(context, "day_pass_adult_cash")) == 9

      set_accepted_networks!(context, "day_pass_adult_cash", [])
      normalize!(context)

      assert pass_rows(context, "day_pass_adult_cash") == []

      # The single-ride rows of the accepting network are untouched by the rebuild.
      assert context |> local_zone_pairs() |> Enum.sort() == Enum.sort(nine_zone_pairs())
    end

    test "a pass accepted on the rows with no network mirrors those rows", context do
      set_accepted_networks!(context, "day_pass_adult_cash", ["all_routes"])
      normalize!(context)

      pass_rows = pass_rows(context, "day_pass_adult_cash")

      assert Enum.all?(pass_rows, &(&1.network_id == nil))
      assert Enum.all?(pass_rows, &(&1.leg_group_id == "all_routes"))
      assert Enum.all?(pass_rows, &(&1.rule_priority == 0))
    end

    test "a pass nobody accepts keeps no row at all", context do
      normalize!(context)

      assert pass_rows(context, "day_pass_reduced_cash") == []
      assert pass_rows(context, "month_pass_adult_app") == []
    end

    test "a new zone rule is given its pass row by the next run", context do
      normalize!(context)

      insert_rule!(context, "local_ride_adult_cash", "N_LOCAL", "NEW", "SEA", nil)

      normalize!(context)

      pass_rows = pass_rows(context, "day_pass_adult_cash")

      assert length(pass_rows) == 10

      assert %FareLegRule{from_area_id: "NEW", to_area_id: "SEA", rule_priority: 7} =
               Enum.find(pass_rows, &(&1.from_area_id == "NEW"))
    end

    test "running twice leaves the same values", context do
      normalize!(context)

      first = rule_values(context)

      normalize!(context)

      assert rule_values(context) == first
    end
  end

  describe "R5 — a difference rule names the destination's product" do
    test "a rule naming a product that left the destination group is refreshed", context do
      # `coast_ride_adult_cash` belongs to the Local group, so this difference
      # rule names a product the Intercity group does not sell.
      align_difference_rule!(context, "coast_ride_adult_cash")

      normalize!(context)

      assert difference_rule(context, "N_INTERCITY").fare_product_id ==
               "intercity_ride_adult_cash"
    end

    test "a rule naming the destination's product already is left alone", context do
      align_difference_rule!(context, "intercity_ride_adult_cash")
      before = difference_rule(context, "N_INTERCITY")

      normalize!(context)

      assert difference_rule(context, "N_INTERCITY") == before
    end

    test "a rule whose destination has no single-ride product keeps its value", context do
      align_difference_rule!(context, "intercity_ride_adult_cash")

      difference_rule(context, "N_INTERCITY")
      |> FareTransferRule.changeset(%{to_leg_group_id: "no_such_group"})
      |> Repo.update!()

      before = difference_rule(context, "no_such_group")

      normalize!(context)

      assert difference_rule(context, "no_such_group") == before
    end

    test "a free transfer rule is not touched", context do
      before = transfer_rule(context, "LG_LOCAL", "LG_LOCAL", 0)

      normalize!(context)

      assert transfer_rule(context, "LG_LOCAL", "LG_LOCAL", 0) == before
    end
  end

  describe "R8 — one default rider type" do
    test "a version with two defaults raises and the transaction rolls back", context do
      assert [row] = rows_with_default(context)
      assert row.rider_category_id == "adult"

      set_default!(context, "reduced", 1)

      assert_raise InvariantError, ~r/exactly one/, fn ->
        Repo.transaction(fn ->
          Normalize.run!(context.organization_id, context.gtfs_version_id)
        end)
      end

      # The rollback is the point: the priorities the run would have written are
      # not stored, and the pass rows it would have deleted are still the imported
      # ones, so the version is exactly as the failed write left it.
      assert Enum.all?(rules(context), &is_nil(&1.rule_priority))

      pass_rows = pass_rows(context, "day_pass_adult_cash")

      assert length(pass_rows) == 1
      assert pass_rows |> Enum.map(& &1.rule_priority) == [nil]
    end

    test "a version with no default at all raises too", context do
      set_default!(context, "adult", 0)

      assert_raise InvariantError, ~r/0 of them are the default/, fn ->
        Repo.transaction(fn ->
          Normalize.run!(context.organization_id, context.gtfs_version_id)
        end)
      end
    end

    test "a version with no rider categories is not this rule's case", context do
      Repo.delete_all(
        from(c in RiderCategory,
          where:
            c.organization_id == ^context.organization_id and
              c.gtfs_version_id == ^context.gtfs_version_id
        )
      )

      normalize!(context)
      assert length(pass_rows(context, "day_pass_adult_cash")) == 9
    end

    test "a version with exactly one default is left alone", context do
      normalize!(context)

      assert [row] = rows_with_default(context)
      assert row.rider_category_id == "adult"
    end
  end

  # An alias of this file's own, so a leftover organization row from an earlier
  # session on the shared test partition cannot collide with this file's fixture.
  defp alias, do: "fares-normalize-#{System.unique_integer([:positive])}"

  # R3's formula, written out here so the expectations do not come from the
  # function under test.
  defp r3_priority(rule) do
    bit(rule.from_timeframe_group_id, 8) + bit(rule.network_id, 4) +
      bit(rule.from_area_id, 2) + bit(rule.to_area_id, 1)
  end

  defp bit(nil, _points), do: 0
  defp bit(_value, points), do: points

  defp leg_group(%{network_id: nil}), do: "all_routes"
  defp leg_group(%{network_id: network_id}), do: network_id

  # The three zones of the fixture in both directions, self pairs included.
  defp nine_zone_pairs do
    for from_area_id <- ~w(NPT TOL CST), to_area_id <- ~w(NPT TOL CST) do
      {from_area_id, to_area_id}
    end
  end

  defp normalize!(context) do
    assert {:ok, :ok} =
             VersionLock.transact(context.scope, fn ->
               Normalize.run!(context.organization_id, context.gtfs_version_id)
             end)
  end

  defp rules(context) do
    FareLegRule
    |> where(
      [r],
      r.organization_id == ^context.organization_id and
        r.gtfs_version_id == ^context.gtfs_version_id
    )
    |> order_by([r],
      asc: r.network_id,
      asc: r.from_area_id,
      asc: r.to_area_id,
      asc: r.fare_product_id
    )
    |> Repo.all()
  end

  # A pass rebuild deletes and reinserts its rows, so the second run's pass rows
  # are new rows. What must not change is what the version says.
  defp rule_values(context) do
    context
    |> rules()
    |> Enum.map(
      &{&1.fare_product_id, &1.network_id, &1.from_area_id, &1.to_area_id,
       &1.from_timeframe_group_id, &1.rule_priority, &1.leg_group_id}
    )
    |> Enum.sort()
  end

  defp local_zone_pairs(context) do
    context
    |> rules()
    |> Enum.filter(&(&1.network_id == "N_LOCAL" and &1.from_area_id != nil))
    |> Enum.map(&{&1.from_area_id, &1.to_area_id})
    |> Enum.uniq()
  end

  defp pass_rows(context, fare_product_id) do
    context
    |> rules()
    |> Enum.filter(&(&1.fare_product_id == fare_product_id))
  end

  defp rule(context, fare_product_id, network_id, from_area_id, to_area_id, timeframe) do
    Enum.find(rules(context), fn row ->
      row.fare_product_id == fare_product_id and row.network_id == network_id and
        row.from_area_id == from_area_id and row.to_area_id == to_area_id and
        row.from_timeframe_group_id == timeframe
    end)
  end

  defp priority_of(context, fare_product_id, network_id, from_area_id, to_area_id, timeframe) do
    case rule(context, fare_product_id, network_id, from_area_id, to_area_id, timeframe) do
      %FareLegRule{rule_priority: priority} -> priority
      nil -> flunk("no rule for #{fare_product_id}")
    end
  end

  defp difference_rule(context, to_leg_group_id) do
    transfer_rule(context, "N_LOCAL", to_leg_group_id, 2)
  end

  defp transfer_rule(context, from_leg_group_id, to_leg_group_id, fare_transfer_type) do
    FareTransferRule
    |> where(
      [t],
      t.organization_id == ^context.organization_id and
        t.gtfs_version_id == ^context.gtfs_version_id and
        t.from_leg_group_id == ^from_leg_group_id and
        t.to_leg_group_id == ^to_leg_group_id and t.fare_transfer_type == ^fare_transfer_type
    )
    |> Repo.all()
    |> case do
      [rule] ->
        rule

      other ->
        flunk(
          "expected one #{from_leg_group_id} to #{to_leg_group_id} transfer rule of type #{fare_transfer_type}, got #{length(other)}"
        )
    end
  end

  # The imported fixture names its transfer groups `LG_LOCAL`/`LG_INTERCITY`; a
  # managed version's leg groups are the network ids R3 gives them, which is
  # what the difference rule's destination group is matched against.
  defp align_difference_rule!(context, fare_product_id) do
    context
    |> rows_in(FareTransferRule)
    |> Enum.find(&(&1.fare_transfer_type == 2))
    |> FareTransferRule.changeset(%{
      from_leg_group_id: "N_LOCAL",
      to_leg_group_id: "N_INTERCITY",
      fare_product_id: fare_product_id
    })
    |> Repo.update!()
  end

  defp rows_with_default(context) do
    RiderCategory
    |> where(
      [c],
      c.organization_id == ^context.organization_id and
        c.gtfs_version_id == ^context.gtfs_version_id and c.is_default_fare_category == 1
    )
    |> Repo.all()
  end

  defp set_default!(context, rider_category_id, value) do
    context
    |> rows_in(RiderCategory)
    |> Enum.find(&(&1.rider_category_id == rider_category_id))
    |> RiderCategory.changeset(%{is_default_fare_category: value})
    |> Repo.update!()
  end

  defp insert_rule!(context, fare_product_id, network_id, from_area_id, to_area_id, timeframe) do
    now = DateTime.utc_now()

    Repo.insert_all(FareLegRule, [
      %{
        id: Ecto.UUID.generate(),
        organization_id: context.organization_id,
        gtfs_version_id: context.gtfs_version_id,
        leg_group_id: leg_group(%{network_id: network_id}),
        network_id: network_id,
        from_area_id: from_area_id,
        to_area_id: to_area_id,
        from_timeframe_group_id: timeframe,
        to_timeframe_group_id: nil,
        fare_product_id: fare_product_id,
        rule_priority: nil,
        inserted_at: now,
        updated_at: now
      }
    ])
  end

  defp mark_managed!(organization_id, gtfs_version_id) do
    {:ok, _setting} =
      %FareVersionSetting{}
      |> Ecto.Changeset.change(%{
        organization_id: organization_id,
        gtfs_version_id: gtfs_version_id,
        managed_at: DateTime.utc_now(),
        older_format: "derived"
      })
      |> Repo.insert()
  end

  # The product kinds the editor would have recorded: the Day pass is accepted on
  # the Local network, the other passes are sold but accepted nowhere.
  defp record_product_kinds!(organization_id, gtfs_version_id) do
    for fare_product_id <- [
          "day_pass_adult_cash",
          "day_pass_reduced_cash",
          "day_pass_youth_cash",
          "month_pass_adult_app",
          "month_pass_reduced_app",
          "month_pass_youth_app"
        ] do
      accepted = if fare_product_id == "day_pass_adult_cash", do: ["N_LOCAL"], else: []

      {:ok, _detail} =
        %FareProductDetail{}
        |> Ecto.Changeset.change(%{
          organization_id: organization_id,
          gtfs_version_id: gtfs_version_id,
          fare_product_id: fare_product_id,
          kind: "pass",
          position: 0,
          accepted_network_ids: accepted
        })
        |> Repo.insert()
    end
  end

  defp set_accepted_networks!(context, fare_product_id, accepted_network_ids) do
    context
    |> rows_in(FareProductDetail)
    |> Enum.find(&(&1.fare_product_id == fare_product_id))
    |> FareProductDetail.changeset(%{accepted_network_ids: accepted_network_ids})
    |> Repo.update!()
  end

  defp rows_in(context, schema) do
    schema
    |> where(
      [row],
      row.organization_id == ^context.organization_id and
        row.gtfs_version_id == ^context.gtfs_version_id
    )
    |> Repo.all()
  end

  # R3's example row, added to the fixture: the Intercity network with a weekday
  # peak departure and no areas.
  defp add_peak_rule!(context) do
    insert_rule!(context, @peak_product, "N_INTERCITY", nil, nil, "weekday_peak")
  end
end
