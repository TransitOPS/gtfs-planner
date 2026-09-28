defmodule GtfsPlanner.Gtfs.Transfers.ScaleTest do
  @moduledoc """
  Merge evidence (EV-13) for the NFR 5.1 load budgets.

  `Gtfs.load_transfer_catalog/3` (through the default `CatalogReadAdapter.Repo`),
  `Gtfs.search_transfer_stops/3` and `Gtfs.create_general_transfer/2` must stay
  inside the requirements' budgets with 1,000 general transfer rules in the
  version: a catalog load within 2 s, a stop search within 500 ms and a create
  within 1 s (NFR 5.1, AC-25).

  Two literal datasets carry the 1,000 rules. The distributed one spreads them
  over 100 stops, 10 routes, 100 trips and 1,000 stop_times and uses all four
  selector shapes (none, from route, from and to route, from trip plus to route).
  The concentrated one puts every rule at station BIG (8 platforms, 20 routes,
  400 trips, 800 stop_times): 40 `BIG → BIG` route rules plus 960 platform rules,
  so the annotation has to evaluate overlap over rules that share one station. Both
  go in with `Repo.insert_all/3`, because one changeset per rule would dominate the
  measurement, and each builder asserts that its rows are unique under the
  six-field `NULLS NOT DISTINCT` key (INV-3) instead of silently measuring fewer
  rules.

  Timings are machine-specific, so every measurement prints one `EV-13` line with
  the dataset, the rule count, the elapsed microseconds, the OTP release and the
  scheduler count, and every budget assert carries the measured value. Each call is
  timed with `:timer.tc/1` on its first (cold) call. The module is tagged
  `:transfer_scale` and excluded from ordinary runs; branch review runs it
  explicitly and saves the output as `evidence/ev-13-scale.txt`:

      MIX_TEST_PARTITION=_xfer15 gtimeout --signal=TERM --kill-after=10s 300s \\
        mix test --only transfer_scale test/gtfs_planner/gtfs/transfers/scale_test.exs
  """
  use GtfsPlanner.DataCase, async: false

  @moduletag :transfer_scale
  @moduletag timeout: 240_000

  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.AuditContext
  alias GtfsPlanner.Gtfs.Route
  alias GtfsPlanner.Gtfs.Stop
  alias GtfsPlanner.Gtfs.StopTime
  alias GtfsPlanner.Gtfs.Transfer
  alias GtfsPlanner.Gtfs.Trip
  alias GtfsPlanner.Repo

  @catalog_budget_us 2_000_000
  @search_budget_us 500_000
  @create_budget_us 1_000_000

  @rules_per_dataset 1_000
  @service_id "WKDY"

  @distributed_stops 100
  @distributed_routes 10
  @distributed_trips 100
  @distributed_stop_times 1_000

  @concentrated_routes 20
  @concentrated_trips 400
  @concentrated_stop_times 800
  @concentrated_stops 9

  describe "NFR 5.1 load budgets" do
    test "the distributed 1,000-rule catalog loads within 2 s" do
      {organization, version} = scope()
      build_distributed!(organization.id, version.id)

      {microseconds, result} =
        :timer.tc(fn -> Gtfs.load_transfer_catalog(organization.id, version.id, []) end)

      assert {:ok, catalog} = result
      assert catalog.counts.general == @rules_per_dataset
      report("distributed catalog (default)", catalog.counts.general, microseconds)

      assert microseconds < @catalog_budget_us,
             "the distributed catalog load took #{microseconds} µs"
    end

    test "the concentrated 1,000-rule catalog loads within 2 s" do
      {organization, version} = scope()
      build_concentrated!(organization.id, version.id)

      {default_us, default} =
        :timer.tc(fn -> Gtfs.load_transfer_catalog(organization.id, version.id, []) end)

      assert {:ok, default_catalog} = default
      assert default_catalog.counts.general == @rules_per_dataset
      report("concentrated catalog (default)", default_catalog.counts.general, default_us)

      {filtered_us, filtered} =
        :timer.tc(fn ->
          Gtfs.load_transfer_catalog(organization.id, version.id,
            search: "big",
            sort_by: :min_time,
            sort_dir: :desc,
            page: 3
          )
        end)

      assert {:ok, filtered_catalog} = filtered
      assert filtered_catalog.total_count == @rules_per_dataset

      report(
        "concentrated catalog (search, min time desc, page 3)",
        filtered_catalog.total_count,
        filtered_us
      )

      {full_us, full} =
        :timer.tc(fn ->
          Gtfs.load_transfer_catalog(organization.id, version.id, per_page: @rules_per_dataset)
        end)

      assert {:ok, full_catalog} = full
      assert length(full_catalog.rows) == @rules_per_dataset
      report("concentrated catalog (every rule, competition check)", @rules_per_dataset, full_us)

      assert Enum.any?(full_catalog.rows, &(&1.competitor_ids != [])),
             "no concentrated rule carries a competitor id, so overlap never ran"

      assert default_us < @catalog_budget_us,
             "the concentrated catalog load took #{default_us} µs"

      assert filtered_us < @catalog_budget_us,
             "the filtered concentrated catalog load took #{filtered_us} µs"
    end

    test "the editor's stop search returns within 500 ms" do
      {organization, version} = scope()
      build_concentrated!(organization.id, version.id)

      {microseconds, result} =
        :timer.tc(fn -> Gtfs.search_transfer_stops(organization.id, version.id, "big") end)

      assert length(result.stops) == @concentrated_stops
      refute result.truncated?
      report("editor stop search \"big\"", length(result.stops), microseconds)

      assert microseconds < @search_budget_us, "the stop search took #{microseconds} µs"
    end

    test "creating one general rule returns within 1 s" do
      {organization, version} = scope()
      build_concentrated!(organization.id, version.id)
      audit = audit_context(organization.id, version.id)

      {microseconds, result} =
        :timer.tc(fn ->
          Gtfs.create_general_transfer(
            %{"from_stop_id" => "BIG-P1", "to_stop_id" => "BIG-P2", "transfer_type" => "0"},
            audit
          )
        end)

      assert {:ok, %Transfer{}} = result
      assert scoped_transfer_count(organization.id, version.id) == @rules_per_dataset + 1
      report("create BIG-P1 -> BIG-P2", @rules_per_dataset, microseconds)

      assert microseconds < @create_budget_us, "the create took #{microseconds} µs"
    end
  end

  defp scope do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)

    {organization, version}
  end

  defp audit_context(organization_id, version_id) do
    actor = user_fixture()

    %AuditContext{
      organization_id: organization_id,
      gtfs_version_id: version_id,
      station_stop_id: nil,
      actor_id: actor.id,
      actor_email: actor.email
    }
  end

  defp scoped_transfer_count(organization_id, version_id) do
    Repo.one(
      from(t in Transfer,
        where: t.organization_id == ^organization_id and t.gtfs_version_id == ^version_id,
        select: count(t.id)
      )
    )
  end

  defp report(dataset, rules, microseconds) do
    IO.puts(
      "EV-13 dataset=#{dataset} rules=#{rules} elapsed_us=#{microseconds} " <>
        "otp=#{System.otp_release()} schedulers=#{System.schedulers_online()}"
    )
  end

  # -- Distributed dataset: 100 stops, 10 routes, 100 trips, 1,000 rules ------

  defp build_distributed!(organization_id, version_id) do
    now = timestamp()

    insert_all!(Stop, distributed_stops(organization_id, version_id, now), @distributed_stops)
    insert_all!(Route, distributed_routes(organization_id, version_id, now), @distributed_routes)
    insert_all!(Trip, distributed_trips(organization_id, version_id, now), @distributed_trips)

    insert_all!(
      StopTime,
      distributed_stop_times(organization_id, version_id, now),
      @distributed_stop_times
    )

    insert_all!(Transfer, distributed_rules(organization_id, version_id, now), @rules_per_dataset)
  end

  defp distributed_stops(organization_id, version_id, now) do
    for index <- 0..(@distributed_stops - 1) do
      stop_id = stop_id(index + 1)

      %{
        id: Ecto.UUID.generate(),
        organization_id: organization_id,
        gtfs_version_id: version_id,
        stop_id: stop_id,
        stop_name: "Distributed Stop #{stop_id}",
        stop_lat: Decimal.from_float(40.0 + rem(index, 10) * 0.001),
        stop_lon: Decimal.from_float(-75.0 + div(index, 10) * 0.001),
        location_type: 0,
        inserted_at: now,
        updated_at: now
      }
    end
  end

  defp distributed_routes(organization_id, version_id, now) do
    for index <- 0..(@distributed_routes - 1) do
      route_id = route_id(index + 1)

      %{
        id: Ecto.UUID.generate(),
        organization_id: organization_id,
        gtfs_version_id: version_id,
        route_id: route_id,
        route_type: 3,
        route_short_name: route_id,
        route_long_name: "Distributed Route #{route_id}",
        active: true,
        inserted_at: now,
        updated_at: now
      }
    end
  end

  defp distributed_trips(organization_id, version_id, now) do
    for index <- 1..@distributed_trips do
      %{
        id: Ecto.UUID.generate(),
        organization_id: organization_id,
        gtfs_version_id: version_id,
        trip_id: trip_id(index),
        route_id: route_id(div(index - 1, 10) + 1),
        service_id: @service_id,
        trip_headsign: "Distributed trip #{index}",
        inserted_at: now,
        updated_at: now
      }
    end
  end

  defp distributed_stop_times(organization_id, version_id, now) do
    for trip <- 1..@distributed_trips, k <- 0..9 do
      %{
        id: Ecto.UUID.generate(),
        organization_id: organization_id,
        gtfs_version_id: version_id,
        trip_id: trip_id(trip),
        stop_id: stop_id(rem(trip + 10 * k, 100) + 1),
        stop_sequence: k + 1,
        arrival_time: clock(8 * 3600 + 120 * k),
        departure_time: clock(8 * 3600 + 120 * k),
        inserted_at: now,
        updated_at: now
      }
    end
  end

  # The card's key walk (`from S(i mod 100 + 1)`, `to S((7i + 3) mod 100 + 1)`,
  # selectors varying with `div(i, 100) mod 4`) repeats its six-field key every 400
  # rules, so it can never reach 1,000 unique keys; the to-side stop shifts by ten
  # stops per 100-rule block, which walks 1,000 distinct stop pairs and keeps the
  # card's four selector shapes and its type and minimum-time assignment.
  defp distributed_rules(organization_id, version_id, now) do
    {_seen, rows} =
      Enum.reduce(0..(@rules_per_dataset - 1), {MapSet.new(), []}, fn index, acc ->
        keep_unique(acc, distributed_rule(index, organization_id, version_id, now))
      end)

    assert length(rows) == @rules_per_dataset,
           "the distributed dataset produced #{length(rows)} unique rule keys, " <>
             "not #{@rules_per_dataset}"

    rows
  end

  defp distributed_rule(index, organization_id, version_id, now) do
    block = div(index, 100)

    attributes = %{
      from_stop_id: stop_id(rem(index, 100) + 1),
      to_stop_id: stop_id(rem(7 * index + 3 + 10 * block, 100) + 1),
      transfer_type: rem(index, 4),
      min_transfer_time: if(rem(index, 4) == 2, do: 120)
    }

    rule_row(
      organization_id,
      version_id,
      now,
      Map.merge(attributes, distributed_selectors(index))
    )
  end

  defp distributed_selectors(index) do
    case rem(div(index, 100), 4) do
      0 ->
        %{}

      1 ->
        %{from_route_id: route_id(rem(index, 10) + 1)}

      2 ->
        %{
          from_route_id: route_id(rem(index, 10) + 1),
          to_route_id: route_id(rem(index + 3, 10) + 1)
        }

      3 ->
        trip = rem(index, 100) + 1

        %{
          from_route_id: route_id(div(trip - 1, 10) + 1),
          from_trip_id: trip_id(trip),
          to_route_id: route_id(rem(index + 5, 10) + 1)
        }
    end
  end

  # -- Concentrated dataset: one station, 20 routes, 400 trips, 1,000 rules ---

  defp build_concentrated!(organization_id, version_id) do
    now = timestamp()

    insert_all!(Stop, concentrated_stops(organization_id, version_id, now), @concentrated_stops)

    insert_all!(
      Route,
      concentrated_routes(organization_id, version_id, now),
      @concentrated_routes
    )

    insert_all!(Trip, concentrated_trips(organization_id, version_id, now), @concentrated_trips)

    insert_all!(
      StopTime,
      concentrated_stop_times(organization_id, version_id, now),
      @concentrated_stop_times
    )

    insert_all!(
      Transfer,
      concentrated_rules(organization_id, version_id, now),
      @rules_per_dataset
    )
  end

  defp concentrated_stops(organization_id, version_id, now) do
    station = %{
      id: Ecto.UUID.generate(),
      organization_id: organization_id,
      gtfs_version_id: version_id,
      stop_id: "BIG",
      stop_name: "Big Station",
      stop_lat: Decimal.from_float(40.0),
      stop_lon: Decimal.from_float(-75.0),
      location_type: 1,
      inserted_at: now,
      updated_at: now
    }

    platforms =
      for index <- 1..8 do
        %{
          id: Ecto.UUID.generate(),
          organization_id: organization_id,
          gtfs_version_id: version_id,
          stop_id: platform_id(index),
          stop_name: "Big Station Platform #{index}",
          stop_lat: Decimal.from_float(40.0 + index * 0.0001),
          stop_lon: Decimal.from_float(-75.0 + index * 0.0001),
          location_type: 0,
          platform_code: "P#{index}",
          parent_station: "BIG",
          inserted_at: now,
          updated_at: now
        }
      end

    [station | platforms]
  end

  defp concentrated_routes(organization_id, version_id, now) do
    for index <- 1..@concentrated_routes do
      route_id = concentrated_route_id(index)

      %{
        id: Ecto.UUID.generate(),
        organization_id: organization_id,
        gtfs_version_id: version_id,
        route_id: route_id,
        route_type: 3,
        route_short_name: route_id,
        route_long_name: "Concentrated Route #{route_id}",
        active: true,
        inserted_at: now,
        updated_at: now
      }
    end
  end

  defp concentrated_trips(organization_id, version_id, now) do
    for route <- 1..@concentrated_routes, trip <- 0..19 do
      route_id = concentrated_route_id(route)

      %{
        id: Ecto.UUID.generate(),
        organization_id: organization_id,
        gtfs_version_id: version_id,
        trip_id: concentrated_trip_id(route, trip),
        route_id: route_id,
        service_id: @service_id,
        trip_headsign: "Concentrated trip #{route_id}-#{pad(trip, 2)}",
        inserted_at: now,
        updated_at: now
      }
    end
  end

  # Trip j of route c serves `BIG-P((c + j) mod 8 + 1)` and then
  # `BIG-P((c + j + 3) mod 8 + 1)`, so every platform has arriving and departing
  # trips for a witness pair.
  defp concentrated_stop_times(organization_id, version_id, now) do
    for route <- 1..@concentrated_routes,
        trip <- 0..19,
        {offset, sequence} <- [{0, 1}, {3, 2}] do
      %{
        id: Ecto.UUID.generate(),
        organization_id: organization_id,
        gtfs_version_id: version_id,
        trip_id: concentrated_trip_id(route, trip),
        stop_id: platform_id(rem(route + trip + offset, 8) + 1),
        stop_sequence: sequence,
        arrival_time: clock(8 * 3600 + (sequence - 1) * 300),
        departure_time: clock(8 * 3600 + (sequence - 1) * 300),
        inserted_at: now,
        updated_at: now
      }
    end
  end

  defp concentrated_rules(organization_id, version_id, now) do
    station_rows =
      Enum.flat_map(1..@concentrated_routes, fn route ->
        route_id = concentrated_route_id(route)

        [
          rule_row(organization_id, version_id, now, %{
            from_stop_id: "BIG",
            to_stop_id: "BIG",
            from_route_id: route_id,
            transfer_type: 2,
            min_transfer_time: 180
          }),
          rule_row(organization_id, version_id, now, %{
            from_stop_id: "BIG",
            to_stop_id: "BIG",
            to_route_id: route_id,
            transfer_type: 1
          })
        ]
      end)

    {seen, platform_rows} =
      Enum.reduce_while(
        0..(@rules_per_dataset - 1),
        {MapSet.new(Enum.map(station_rows, &rule_key/1)), []},
        fn k, acc ->
          acc = add_platform_block(k, organization_id, version_id, now, acc)

          if MapSet.size(elem(acc, 0)) == @rules_per_dataset do
            {:halt, acc}
          else
            {:cont, acc}
          end
        end
      )

    assert MapSet.size(seen) == @rules_per_dataset,
           "the concentrated dataset produced #{MapSet.size(seen)} unique rule keys, " <>
             "not #{@rules_per_dataset}"

    total = length(station_rows) + length(platform_rows)

    assert total == @rules_per_dataset,
           "the concentrated dataset kept #{total} rules, not #{@rules_per_dataset}"

    station_rows ++ platform_rows
  end

  defp add_platform_block(k, organization_id, version_id, now, {seen, rows}) do
    candidates =
      for p <- 1..8, q <- 1..8 do
        platform_rule(k, p, q, organization_id, version_id, now)
      end

    Enum.reduce(candidates, {seen, rows}, &keep_unique(&2, &1))
  end

  defp platform_rule(k, p, q, organization_id, version_id, now) do
    transfer_type = rem(p + q + k, 4)

    rule_row(organization_id, version_id, now, %{
      from_stop_id: platform_id(p),
      to_stop_id: platform_id(q),
      from_route_id: concentrated_route_id(rem(k, 20) + 1),
      to_route_id: concentrated_route_id(rem(3 * k + p + q, 20) + 1),
      transfer_type: transfer_type,
      min_transfer_time: if(transfer_type == 2, do: 120)
    })
  end

  # -- Row shapes -------------------------------------------------------------

  defp rule_row(organization_id, version_id, now, attributes) do
    Map.merge(
      %{
        id: Ecto.UUID.generate(),
        organization_id: organization_id,
        gtfs_version_id: version_id,
        from_stop_id: nil,
        to_stop_id: nil,
        from_route_id: nil,
        to_route_id: nil,
        from_trip_id: nil,
        to_trip_id: nil,
        transfer_type: 0,
        min_transfer_time: nil,
        inserted_at: now,
        updated_at: now
      },
      attributes
    )
  end

  defp keep_unique({seen, rows}, attributes) do
    key = rule_key(attributes)

    if MapSet.member?(seen, key) do
      {seen, rows}
    else
      {MapSet.put(seen, key), [attributes | rows]}
    end
  end

  defp rule_key(attributes) do
    {
      attributes.from_stop_id,
      attributes.to_stop_id,
      attributes.from_route_id,
      attributes.to_route_id,
      attributes.from_trip_id,
      attributes.to_trip_id
    }
  end

  defp insert_all!(schema, rows, expected) do
    {count, nil} = Repo.insert_all(schema, rows)

    assert count == expected,
           "inserted #{count} #{inspect(schema)} rows, expected #{expected}"
  end

  defp timestamp, do: DateTime.truncate(DateTime.utc_now(), :microsecond)

  defp stop_id(index), do: "S" <> pad(index, 3)
  defp route_id(index), do: "R" <> pad(index, 2)
  defp trip_id(index), do: "T" <> pad(index, 3)
  defp concentrated_route_id(index), do: "C" <> pad(index, 2)
  defp platform_id(index), do: "BIG-P#{index}"
  defp concentrated_trip_id(route, trip), do: concentrated_route_id(route) <> "-" <> pad(trip, 2)

  defp pad(value, width), do: value |> Integer.to_string() |> String.pad_leading(width, "0")

  defp clock(seconds) do
    hours = div(seconds, 3600)
    minutes = div(rem(seconds, 3600), 60)

    "#{pad(hours, 2)}:#{pad(minutes, 2)}:#{pad(rem(seconds, 60), 2)}"
  end
end
