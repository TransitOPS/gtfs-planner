defmodule GtfsPlanner.Gtfs.Fares.BranchRepairsTest do
  use GtfsPlanner.DataCase, async: true

  import GtfsPlanner.AccountsFixtures, only: [editor_fixture: 1]
  import GtfsPlanner.FaresFixtures, only: [import!: 3]
  import GtfsPlanner.OrganizationsFixtures, only: [organization_fixture: 1]
  import GtfsPlanner.VersionsFixtures, only: [gtfs_version_fixture: 2]

  alias GtfsPlanner.Gtfs.AuditContext
  alias GtfsPlanner.Gtfs.ChangeLog
  alias GtfsPlanner.Gtfs.FareLegRule
  alias GtfsPlanner.Gtfs.FareProduct
  alias GtfsPlanner.Gtfs.Fares
  alias GtfsPlanner.Gtfs.Fares.Conversion
  alias GtfsPlanner.Gtfs.Fares.Interpreter
  alias GtfsPlanner.Gtfs.Fares.Interpreter.Rows
  alias GtfsPlanner.Gtfs.Fares.Pricing
  alias GtfsPlanner.Gtfs.Fares.Projection
  alias GtfsPlanner.Gtfs.Fares.Transfers
  alias GtfsPlanner.Gtfs.FareTransferRule
  alias GtfsPlanner.Gtfs.RiderCategory
  alias GtfsPlanner.Gtfs.Route
  alias GtfsPlanner.Gtfs.RouteNetwork
  alias GtfsPlanner.Repo

  setup do
    org = organization_fixture(%{alias: "repair-#{System.unique_integer([:positive])}"})
    actor = editor_fixture(org)
    version = gtfs_version_fixture(org.id, %{name: "Fare repairs"})

    scope = %{
      organization_id: org.id,
      gtfs_version_id: version.id,
      audit: %AuditContext{
        organization_id: org.id,
        gtfs_version_id: version.id,
        actor_id: actor.id,
        actor_email: actor.email
      }
    }

    %{organization: org, version: version, scope: scope}
  end

  test "conversion copies legacy route network columns when membership rows are absent",
       context do
    import!(context.organization, context.version, "north_coast_v2")

    memberships =
      Repo.all(from r in RouteNetwork, where: r.gtfs_version_id == ^context.version.id)

    for row <- memberships do
      from(r in Route,
        where: r.gtfs_version_id == ^context.version.id and r.route_id == ^row.route_id
      )
      |> Repo.update_all(set: [network_id: row.network_id])
    end

    from(r in RouteNetwork, where: r.gtfs_version_id == ^context.version.id) |> Repo.delete_all()

    assert {:ok, plan} = Conversion.preview(context.organization.id, context.version.id)
    assert length(plan.route_networks) == 14
    assert {:ok, _} = Conversion.apply(context.scope, plan.fingerprint, [])

    assert Enum.count(
             Repo.all(from r in RouteNetwork, where: r.gtfs_version_id == ^context.version.id)
           ) == 14
  end

  for kind <- [:free, :flat, :route] do
    test "#{kind} setup projects a reachable fare without zones", context do
      import!(context.organization, context.version, "no_fare")
      # Removing the fixture's zones models the ordinary version before zones are drawn.
      from(s in GtfsPlanner.Gtfs.Stop, where: s.organization_id == ^context.organization.id)
      |> Repo.update_all(set: [zone_id: nil])

      answers =
        case unquote(kind) do
          :free -> %{kind: :free}
          :flat -> %{kind: :flat, adult: "2.00"}
          :route -> %{kind: :route, groups: [{"Local", "2.00"}]}
        end

      assert {:ok, _} = Conversion.setup(context.scope, answers)
      projected = Projection.v1_rows(context.organization.id, context.version.id)
      assert [_ | _] = projected["fare_attributes.txt"]
      assert [_ | _] = projected["fare_rules.txt"]

      refute Enum.any?(
               Fares.Checks.run(context.organization.id, context.version.id).repair,
               &(&1.code == "route_without_fare")
             )
    end
  end

  test "projection uses the flag equal to one after a nondefault row", context do
    setup_flat(context)

    adult =
      Repo.one!(from r in RiderCategory, where: r.organization_id == ^context.organization.id)

    adult |> Ecto.Changeset.change(is_default_fare_category: 0) |> Repo.update!()

    Repo.insert!(%RiderCategory{
      organization_id: context.organization.id,
      gtfs_version_id: context.version.id,
      rider_category_id: "reduced",
      rider_category_name: "Reduced",
      is_default_fare_category: 1
    })

    Repo.insert!(%FareProduct{
      organization_id: context.organization.id,
      gtfs_version_id: context.version.id,
      fare_product_id: "local_ride",
      fare_product_name: "Local ride",
      rider_category_id: "reduced",
      fare_media_id: "cash",
      amount: Decimal.new("0.50"),
      currency: "USD"
    })

    assert [%{price: price}] =
             Projection.v1_rows(context.organization.id, context.version.id)[
               "fare_attributes.txt"
             ]

    assert Decimal.equal?(price, Decimal.new("0.50"))
  end

  test "a timed discount keeps the dearer base in the older projection and activates only on its weekdays",
       context do
    setup_flat(context, "6.00")

    assert {:ok, _} =
             Fares.save_time_period(context.scope, %{
               name: "Monday peak",
               weekdays: 1,
               ranges: [%{start_seconds: 25_200, end_seconds: 32_400}]
             })

    assert {:ok, _} =
             Fares.save_fare(context.scope, %{
               name: "Peak ride",
               kind: "single",
               media_ids: ["cash"],
               prices: %{"adult" => "4.00"}
             })

    assert {:ok, _} =
             Fares.save_rule(
               context.scope,
               %{
                 fare_product_id: "peak_ride",
                 from_timeframe_group_id: "monday_peak",
                 reviewed: []
               },
               nil
             )

    rows = Interpreter.load_rows(context.organization.id, context.version.id)

    for {date, departure, expected} <- [
          {~D[2026-09-07], 24_000, "6"},
          {~D[2026-09-07], 27_000, "4"},
          {~D[2026-09-07], 33_000, "6"},
          {~D[2026-09-08], 27_000, "6"}
        ] do
      assert Decimal.equal?(
               Pricing.price_journey(rows, journey(date, departure)).total,
               Decimal.new(expected)
             )
    end

    projection = Projection.v1_rows(context.organization.id, context.version.id)

    assert Enum.find(
             projection["fare_rules.txt"],
             &(&1.origin_id == nil and &1.destination_id == nil)
           ).fare_id == "local_ride"
  end

  test "a paid same-group transfer remains a fee and gives no older free allowance", context do
    setup_flat(context)

    assert {:ok, saved} =
             Transfers.save(
               context.scope,
               "all_routes",
               "all_routes",
               %{pay: :fee, minutes: 90, fee: "0.25", count: -1},
               nil
             )

    {:ok, workspace} = Fares.load_workspace(context.organization.id, context.version.id)

    policy =
      Enum.find(
        workspace.transfers,
        &(&1.from_leg_group_id == "all_routes" and &1.to_leg_group_id == "all_routes")
      ).policy

    assert policy.pay == :fee
    assert Decimal.equal?(policy.fee_amount, Decimal.new("0.25"))

    assert {:ok, edited} =
             Transfers.save(
               context.scope,
               "all_routes",
               "all_routes",
               %{pay: :fee, minutes: 60, fee: "0.50", count: -1},
               %{pay: :fee, minutes: 90, fee: "0.25", count: -1}
             )

    assert {:ok, _} = Fares.undo(context.scope, edited.operation_id, edited.inverse)

    assert [%{transfers: 0}] =
             Projection.v1_rows(context.organization.id, context.version.id)[
               "fare_attributes.txt"
             ]

    rows = Interpreter.load_rows(context.organization.id, context.version.id)
    two = %{journey() | legs: journey().legs ++ journey().legs}
    assert Decimal.equal?(Pricing.price_journey(rows, two).total, Decimal.new("2.25"))
    projected = Projection.v1_rows(context.organization.id, context.version.id)

    older = %{
      rows
      | fare_attributes: projected["fare_attributes.txt"],
        fare_rules: projected["fare_rules.txt"]
    }

    assert Decimal.equal?(Interpreter.price_journey_v1(older, two).total, Decimal.new("4"))
    assert saved.inverse
  end

  for source <- ["north_coast_v1", "north_coast_v2"] do
    test "#{source} conversion inverse refuses a subsequent price edit", context do
      import!(context.organization, context.version, unquote(source))
      {:ok, plan} = Conversion.preview(context.organization.id, context.version.id)
      assert {:ok, converted} = Conversion.apply(context.scope, plan.fingerprint, [])

      product =
        Repo.one!(
          from p in FareProduct, where: p.organization_id == ^context.organization.id, limit: 1
        )

      assert {:ok, _} =
               Fares.save_prices(context.scope, [
                 %{
                   fare_product_id: product.fare_product_id,
                   rider_category_id: product.rider_category_id,
                   fare_media_id: product.fare_media_id,
                   reviewed: product.amount,
                   amount: "9.00"
                 }
               ])

      before = snapshot(context)

      assert {:error, :stale} =
               Fares.undo(context.scope, converted.operation_id, converted.inverse)

      assert snapshot(context) == before
    end
  end

  test "setup inverse refuses subsequent fare work", context do
    saved = setup_flat(context)

    assert {:ok, _} =
             Fares.save_prices(context.scope, [
               %{
                 fare_product_id: "local_ride",
                 rider_category_id: "adult",
                 fare_media_id: "cash",
                 reviewed: Decimal.new("2.00"),
                 amount: "3.00"
               }
             ])

    before = snapshot(context)
    assert {:error, :stale} = Fares.undo(context.scope, saved.operation_id, saved.inverse)
    assert snapshot(context) == before
  end

  test "existing drawers require the persisted snapshot and refuse another editor's change",
       context do
    setup_flat(context)
    review = snapshot(context)

    forms = [
      {&Fares.save_fare/2,
       %{
         fare_product_id: "local_ride",
         name: "Rename",
         kind: "single",
         media_ids: ["cash"],
         prices: %{"adult" => "2.00"}
       }},
      {&Fares.save_rider_type/2, %{rider_category_id: "adult", name: "Standard", default?: true}},
      {&Fares.save_payment_method/2,
       %{
         fare_media_id: "cash",
         name: "Cash renamed",
         fare_media_type: 0,
         fare_product_ids: ["local_ride"]
       }}
    ]

    for {writer, params} <- forms do
      assert {:error, :stale} = writer.(context.scope, params)

      assert {:error, :stale} =
               writer.(context.scope, Map.put(params, :reviewed_snapshot, "forged"))
    end

    assert {:ok, _} =
             Fares.save_prices(context.scope, [
               %{
                 fare_product_id: "local_ride",
                 rider_category_id: "adult",
                 fare_media_id: "cash",
                 reviewed: Decimal.new("2.00"),
                 amount: "3.00"
               }
             ])

    for {writer, params} <- forms do
      assert {:error, :stale} =
               writer.(context.scope, Map.put(params, :reviewed_snapshot, review))
    end

    assert Decimal.equal?(
             Repo.one!(
               from p in FareProduct, where: p.organization_id == ^context.organization.id
             ).amount,
             Decimal.new("3")
           )
  end

  test "group and period edits require snapshots of their memberships and ranges", context do
    setup_flat(context)
    assert {:ok, _} = Fares.save_route_group(context.scope, %{name: "Local", route_ids: ["1"]})

    assert {:ok, _} =
             Fares.save_time_period(context.scope, %{
               name: "Peak",
               ranges: [%{start_seconds: 0, end_seconds: 3600}]
             })

    review = snapshot(context)

    for {writer, params} <- [
          {&Fares.save_route_group/2, %{network_id: "local", name: "Renamed", route_ids: []}},
          {&Fares.save_time_period/2,
           %{
             timeframe_group_id: "peak",
             name: "Renamed",
             ranges: [%{start_seconds: 0, end_seconds: 7200}]
           }}
        ] do
      assert {:error, :stale} = writer.(context.scope, params)

      assert {:ok, _} =
               writer.(context.scope, Map.put(params, :reviewed_snapshot, snapshot(context)))

      assert {:error, :stale} =
               writer.(context.scope, Map.put(params, :reviewed_snapshot, review))
    end
  end

  test "a second grouped fare refusal rolls back the first edit and its history", context do
    setup_flat(context)

    assert {:ok, _} =
             Fares.save_fare(context.scope, %{
               name: "Second",
               kind: "single",
               media_ids: ["cash"],
               prices: %{"adult" => "3"}
             })

    review = snapshot(context)

    before_logs =
      Repo.aggregate(
        from(l in ChangeLog, where: l.organization_id == ^context.organization.id),
        :count
      )

    good = %{
      name: "First renamed",
      fare_product_id: "local_ride",
      kind: "single",
      media_ids: ["cash"],
      prices: %{"adult" => "2"},
      reviewed_snapshot: review
    }

    bad =
      %{good | name: "Second renamed", fare_product_id: "second", prices: %{"adult" => "3"}}
      |> Map.put(:reviewed, [
        %{
          fare_product_id: "second",
          rider_category_id: "adult",
          fare_media_id: "cash",
          reviewed: Decimal.new("99")
        }
      ])

    assert {:error, {:stale, _}} = Fares.save_fares(context.scope, [good, bad])
    assert snapshot(context) == review

    assert Repo.aggregate(
             from(l in ChangeLog, where: l.organization_id == ^context.organization.id),
             :count
           ) == before_logs

    assert {:ok, result} = Fares.save_fares(context.scope, [good, Map.delete(bad, :reviewed)])

    assert Repo.aggregate(
             from(l in ChangeLog, where: l.organization_id == ^context.organization.id),
             :count
           ) == before_logs + 1

    assert {:ok, _} = Fares.undo(context.scope, result.operation_id, result.inverse)
    assert snapshot(context) == review
  end

  test "malformed retained default categories refuse conversion before apply", context do
    import!(context.organization, context.version, "north_coast_v2")

    from(r in RiderCategory, where: r.organization_id == ^context.organization.id)
    |> Repo.update_all(set: [is_default_fare_category: nil])

    assert {:refused, [%{code: :default_rider}]} =
             Conversion.preview(context.organization.id, context.version.id)

    assert {:refused, [%{code: :default_rider}]} =
             Conversion.apply(context.scope, "stale", [])

    from(r in RiderCategory, where: r.organization_id == ^context.organization.id)
    |> Repo.update_all(set: [is_default_fare_category: 1])

    assert {:refused, [%{code: :default_rider}]} =
             Conversion.preview(context.organization.id, context.version.id)
  end

  test "empty v1 transfers convert to unlimited and survive the projection round trip", context do
    import!(context.organization, context.version, "north_coast_v1")

    from(f in GtfsPlanner.Gtfs.FareAttribute,
      where: f.organization_id == ^context.organization.id
    )
    |> Repo.update_all(set: [transfers: nil, transfer_duration: nil])

    {:ok, plan} = Conversion.preview(context.organization.id, context.version.id)
    assert {:ok, _} = Conversion.apply(context.scope, plan.fingerprint, [])
    rows = Interpreter.load_rows(context.organization.id, context.version.id)
    assert Enum.all?(rows.fare_transfer_rules, &(&1.transfer_count == -1))

    leg = %{
      route_id: "1",
      from_stop_id: "NTC",
      to_stop_id: "HOSP",
      departs: 27_000,
      arrives: 27_600
    }

    trip = %{journey() | legs: [leg, %{leg | departs: 28_000, arrives: 28_600}]}
    assert Decimal.equal?(Pricing.price_journey(rows, trip).total, Decimal.new("1.50"))
    projection = Projection.v1_rows(context.organization.id, context.version.id)

    older = %{
      rows
      | fare_attributes: projection["fare_attributes.txt"],
        fare_rules: projection["fare_rules.txt"]
    }

    assert Decimal.equal?(Interpreter.price_journey_v1(older, trip).total, Decimal.new("1.50"))
  end

  for {label, mapping} <- [
        {"swapped", %{"LG_LOCAL" => "N_INTERCITY", "LG_INTERCITY" => "N_LOCAL"}},
        {"chained", %{"LG_LOCAL" => "N_INTERCITY", "LG_INTERCITY" => "OTHER"}}
      ] do
    test "#{label} imported transfer labels are rewritten once and undo restores both endpoints",
         context do
      import!(context.organization, context.version, "north_coast_v2")
      mapping = unquote(Macro.escape(mapping))

      rules =
        Repo.all(from r in FareLegRule, where: r.organization_id == ^context.organization.id)

      for rule <- rules do
        rule
        |> Ecto.Changeset.change(
          leg_group_id: Map.get(mapping, rule.leg_group_id, rule.leg_group_id)
        )
        |> Repo.update!()
      end

      transfers =
        Repo.all(from r in FareTransferRule, where: r.organization_id == ^context.organization.id)

      for rule <- transfers do
        rule
        |> Ecto.Changeset.change(
          from_leg_group_id: Map.get(mapping, rule.from_leg_group_id, rule.from_leg_group_id),
          to_leg_group_id: Map.get(mapping, rule.to_leg_group_id, rule.to_leg_group_id)
        )
        |> Repo.update!()
      end

      original = transfer_endpoints(context)

      trip = %{
        journey()
        | legs: [
            %{
              route_id: "4",
              from_stop_id: "TOLEDO",
              to_stop_id: "NTC",
              departs: 27_000,
              arrives: 27_600
            },
            %{
              route_id: "10",
              from_stop_id: "NTC",
              to_stop_id: "CORVALLIS",
              departs: 28_000,
              arrives: 28_600
            }
          ]
      }

      before =
        Pricing.price_journey(
          Interpreter.load_rows(context.organization.id, context.version.id),
          trip
        )

      {:ok, plan} = Conversion.preview(context.organization.id, context.version.id)
      assert {:ok, converted} = Conversion.apply(context.scope, plan.fingerprint, [])

      after_price =
        Pricing.price_journey(
          Interpreter.load_rows(context.organization.id, context.version.id),
          trip
        )

      assert Decimal.equal?(before.total, after_price.total)

      normal =
        Map.new(mapping, fn {old, imported} ->
          {imported, if(old == "LG_LOCAL", do: "N_LOCAL", else: "N_INTERCITY")}
        end)

      assert transfer_endpoints(context) ==
               Enum.map(original, fn {id, from, to} ->
                 {id, Map.get(normal, from, from), Map.get(normal, to, to)}
               end)

      assert {:ok, _} = Fares.undo(context.scope, converted.operation_id, converted.inverse)
      assert transfer_endpoints(context) == original
    end
  end

  test "managed route membership wins over a retained network column in the projection",
       context do
    import!(context.organization, context.version, "north_coast_v2")
    {:ok, plan} = Conversion.preview(context.organization.id, context.version.id)
    assert {:ok, _} = Conversion.apply(context.scope, plan.fingerprint, [])

    from(r in Route, where: r.organization_id == ^context.organization.id and r.route_id == "4")
    |> Repo.update_all(set: [network_id: "N_INTERCITY"])

    projection = Projection.v1_rows(context.organization.id, context.version.id)

    assert Enum.any?(
             projection["fare_rules.txt"],
             &(&1.fare_id == "valley_ride" and &1.route_id == "4")
           )
  end

  defp transfer_endpoints(context) do
    Repo.all(
      from r in FareTransferRule,
        where: r.organization_id == ^context.organization.id,
        order_by: r.id,
        select: {r.id, r.from_leg_group_id, r.to_leg_group_id}
    )
  end

  test "type one charges A plus AB plus B throughout a chain" do
    for {fee, expected} <- [{"0.50", "9.00"}, {nil, "8.00"}] do
      rows = literal_rows(1, fee)

      assert Decimal.equal?(
               Pricing.price_journey(rows, literal_journey(3)).total,
               Decimal.new(expected)
             )
    end
  end

  test "a missing named fee price reports an unpriced problem while no fee id is free" do
    rows = literal_rows(0, "0.50")

    rows = %{
      rows
      | fare_products:
          Enum.map(rows.fare_products, fn p ->
            if p.fare_product_id == "fee", do: %{p | rider_category_id: "adult"}, else: p
          end)
    }

    result = Pricing.price_journey(rows, %{literal_journey(2) | rider_category_id: "reduced"})
    assert [_ | _] = result.problems
    assert Decimal.equal?(result.total, Decimal.new("5"))
    free = literal_rows(0, nil)
    assert Pricing.price_journey(free, literal_journey(2)).problems == []
    assert Decimal.equal?(Pricing.price_journey(free, literal_journey(2)).total, Decimal.new("2"))
  end

  test "blank v1 transfers remain unlimited across many legs" do
    rows = %Rows{
      fare_attributes: [
        %{
          fare_id: "ride",
          price: Decimal.new("2"),
          transfers: nil,
          transfer_duration: nil,
          currency_type: "USD",
          payment_method: 0
        }
      ],
      fare_rules: [
        %{fare_id: "ride", route_id: nil, origin_id: nil, destination_id: nil, contains_id: nil}
      ]
    }

    assert Decimal.equal?(
             Interpreter.price_journey_v1(rows, literal_journey(5)).total,
             Decimal.new("2")
           )
  end

  defp setup_flat(context, amount \\ "2.00") do
    import!(context.organization, context.version, "no_fare")
    {:ok, result} = Conversion.setup(context.scope, %{kind: :flat, adult: amount})
    result
  end

  defp snapshot(context), do: Fares.reviewed_snapshot(context.organization.id, context.version.id)

  defp journey(date \\ ~D[2026-09-07], departure \\ 27_000),
    do: %{
      rider_category_id: "adult",
      fare_media_id: "cash",
      service_date: date,
      legs: [
        %{
          route_id: "1",
          from_stop_id: "A",
          to_stop_id: "B",
          departs: departure,
          arrives: departure + 600
        }
      ]
    }

  defp literal_journey(count),
    do: %{
      rider_category_id: "reduced",
      fare_media_id: "cash",
      service_date: ~D[2026-09-07],
      legs:
        for(
          i <- 1..count,
          do: %{
            route_id: if(i == 1, do: "a", else: "b"),
            from_stop_id: "A",
            to_stop_id: "B",
            departs: i * 600,
            arrives: i * 600 + 300
          }
        )
    }

  defp literal_rows(type, fee) do
    products = [
      %FareProduct{fare_product_id: "a", amount: Decimal.new("2"), currency: "USD"},
      %FareProduct{fare_product_id: "b", amount: Decimal.new("3"), currency: "USD"}
    ]

    products =
      if fee,
        do:
          products ++
            [%FareProduct{fare_product_id: "fee", amount: Decimal.new(fee), currency: "USD"}],
        else: products

    %Rows{
      fare_products: products,
      route_networks: %{"a" => "a", "b" => "b"},
      fare_leg_rules: [
        %FareLegRule{
          fare_product_id: "a",
          network_id: "a",
          leg_group_id: "group",
          rule_priority: 1
        },
        %FareLegRule{
          fare_product_id: "b",
          network_id: "b",
          leg_group_id: "group",
          rule_priority: 1
        }
      ],
      fare_transfer_rules: [
        %FareTransferRule{
          from_leg_group_id: "group",
          to_leg_group_id: "group",
          fare_transfer_type: type,
          fare_product_id: if(fee, do: "fee"),
          transfer_count: -1
        }
      ]
    }
  end
end
