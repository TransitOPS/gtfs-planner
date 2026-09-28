defmodule GtfsPlanner.Gtfs.Transfers.CatalogTest do
  @moduledoc """
  Merge evidence (EV-4) for the transfer catalog load and annotation.

  `Transfers.load_catalog/3` must load one version's transfers from real queries,
  split the general (types 0-3) and in-seat (types 4-5) views, and annotate every
  row with resolved endpoints, selectors, GTFS rank, R11 attention reasons,
  competitor ids from the real `stop_time` incidence and its exact mirror.

  The cases use the shared literal network (`TransfersFixtures`) and expect
  literal annotation values, so a catalog that leaks another organization's or
  version's rows, ignores station coverage, omits an attention reason, invents a
  competition flag without a witness trip pair, or links a mirror across views is
  rejected here. EV-4 does not prove the listing options (EV-5), the adapter and
  facade wiring (EV-6) or the NFR 5.1 budget (EV-13).
  """
  use GtfsPlanner.DataCase, async: true

  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Gtfs.Stop
  alias GtfsPlanner.Gtfs.StopTime
  alias GtfsPlanner.Gtfs.Transfer
  alias GtfsPlanner.Gtfs.Transfers
  alias GtfsPlanner.TransfersFixtures

  @query_event [:gtfs_planner, :repo, :query]
  @query_sources ~w(transfers stops trips routes stop_times)

  setup do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    TransfersFixtures.transfer_network_fixture(organization.id, version.id)

    %{organization: organization, version: version}
  end

  describe "views and counts" do
    test "lists general rules by default and type 4/5 rows only in the in-seat view", ctx do
      general = [
        transfer(ctx, %{from_stop_id: "CEN-A", to_stop_id: "CEN-C", transfer_type: 0}),
        transfer(ctx, %{
          from_stop_id: "CEN",
          to_stop_id: "CEN",
          from_route_id: "12",
          transfer_type: 2,
          min_transfer_time: 120
        }),
        transfer(ctx, %{from_stop_id: "MKT", to_stop_id: "HBR", transfer_type: 1})
      ]

      in_seat = [
        transfer(ctx, %{from_trip_id: "12-0815", to_trip_id: "24-0840", transfer_type: 4}),
        transfer(ctx, %{
          from_stop_id: "MKT",
          to_stop_id: "HBR",
          from_trip_id: "12-1010",
          to_trip_id: "24-0920",
          transfer_type: 5
        })
      ]

      default_catalog = load(ctx)
      general_catalog = load(ctx, view: :general)
      in_seat_catalog = load(ctx, view: :in_seat)

      assert default_catalog.view == :general
      assert default_catalog.rows == general_catalog.rows
      assert row_ids(general_catalog) == sorted_ids(general)
      assert general_catalog.total_count == 3
      assert general_catalog.page == 1
      assert general_catalog.per_page == 50
      assert general_catalog.counts == %{general: 3, in_seat: 2}

      assert general_catalog.filter_options == %{
               stops: [
                 %{stop_id: "CEN", name: "Central Station"},
                 %{stop_id: "HBR", name: "Harbor"},
                 %{stop_id: "MKT", name: "Market Street"}
               ],
               routes: [%{route_id: "12", route_short_name: "12", route_long_name: "Riverside"}],
               types: [0, 1, 2, 3]
             }

      assert in_seat_catalog.view == :in_seat
      assert row_ids(in_seat_catalog) == sorted_ids(in_seat)
      assert in_seat_catalog.total_count == 2
      assert in_seat_catalog.per_page == 50
      assert in_seat_catalog.counts == %{general: 3, in_seat: 2}

      assert in_seat_catalog.filter_options == %{
               stops: [
                 %{stop_id: "HBR", name: "Harbor"},
                 %{stop_id: "MKT", name: "Market Street"}
               ],
               routes: [
                 %{route_id: "12", route_short_name: "12", route_long_name: "Riverside"},
                 %{route_id: "24", route_short_name: "24", route_long_name: "Harbor"}
               ],
               types: [4, 5]
             }
    end

    test "returns an empty first page when the version has no rules", ctx do
      catalog = load(ctx)

      assert catalog.rows == []
      assert catalog.total_count == 0
      assert catalog.page == 1
      assert catalog.per_page == 50
      assert catalog.selected == nil
      assert catalog.competitors == []
      assert catalog.counts == %{general: 0, in_seat: 0}
    end

    test "returns an empty catalog for a mismatched organization and version", ctx do
      transfer(ctx, %{from_stop_id: "CEN-A", to_stop_id: "CEN-C", transfer_type: 0})

      other_organization = organization_fixture()
      other_version = gtfs_version_fixture(other_organization.id)

      for {organization_id, version_id} <- [
            {other_organization.id, ctx.version.id},
            {ctx.organization.id, other_version.id}
          ] do
        catalog = Transfers.load_catalog(organization_id, version_id)

        assert catalog.rows == []
        assert catalog.counts == %{general: 0, in_seat: 0}
        assert catalog.selected == nil
        assert catalog.competitors == []
      end
    end
  end

  describe "tenant scope" do
    test "never loads another version's or another organization's rules or references", ctx do
      organization_id = ctx.organization.id
      version_id = ctx.version.id

      own =
        transfer(ctx, %{from_stop_id: "CEN-A", to_stop_id: "CEN-C", transfer_type: 0})

      second_version = gtfs_version_fixture(organization_id)
      TransfersFixtures.transfer_network_fixture(organization_id, second_version.id)

      Repo.update_all(
        from(s in Stop,
          where:
            s.organization_id == ^organization_id and
              s.gtfs_version_id == ^second_version.id and s.stop_id == "CEN-A"
        ),
        set: [stop_name: "Second Version Bay A"]
      )

      twin =
        transfer_fixture(organization_id, second_version.id, %{
          from_stop_id: "CEN-A",
          to_stop_id: "CEN-C",
          transfer_type: 0
        })

      stop_fixture(organization_id, second_version.id, %{
        stop_id: "V2ONLY",
        stop_name: "Version Two Only"
      })

      trip_fixture(organization_id, second_version.id, "12", %{
        trip_id: "X-0001",
        service_id: "WKDY"
      })

      other_organization = organization_fixture()
      other_version = gtfs_version_fixture(other_organization.id)
      TransfersFixtures.transfer_network_fixture(other_organization.id, other_version.id)

      foreign =
        transfer_fixture(other_organization.id, other_version.id, %{
          from_stop_id: "CEN-A",
          to_stop_id: "CEN-C",
          transfer_type: 0
        })

      dangling =
        transfer_fixture(organization_id, version_id, %{
          from_stop_id: "V2ONLY",
          to_stop_id: "MUS",
          from_trip_id: "X-0001",
          transfer_type: 0
        })

      stored_count = Repo.aggregate(Transfer, :count)
      catalog = load(ctx)

      assert row_ids(catalog) == sorted_ids([own, dangling])
      assert catalog.counts == %{general: 2, in_seat: 0}
      refute twin.id in row_ids(catalog)
      refute foreign.id in row_ids(catalog)

      assert row(catalog, own).from.name == "Central · Bay A"
      assert row(catalog, dangling).from.stop_id == "V2ONLY"
      assert row(catalog, dangling).from.name == nil
      assert row(catalog, dangling).from.top_level == nil

      assert row(catalog, dangling).attention == [
               {:missing_stop, :from, "V2ONLY"},
               {:missing_trip, :from, "X-0001"}
             ]

      assert Repo.aggregate(Transfer, :count) == stored_count
    end
  end

  describe "endpoint annotation" do
    test "resolves a platform's station context and a station's child count", ctx do
      platform =
        transfer(ctx, %{from_stop_id: "CEN-A", to_stop_id: "CEN-C", transfer_type: 0})

      station =
        transfer(ctx, %{from_stop_id: "CEN", to_stop_id: "CEN", transfer_type: 0})

      catalog = load(ctx)
      from = row(catalog, platform).from

      assert from.stop_id == "CEN-A"
      assert from.name == "Central · Bay A"
      assert from.platform_code == "A"
      assert from.location_type == 0
      assert from.top_level == %{stop_id: "CEN", name: "Central Station"}
      assert from.child_count == 0
      assert from.selector == :any
      assert from.route == nil

      assert row(catalog, platform).to.name == "Central · Bay C"
      assert row(catalog, platform).to.platform_code == "C"

      station_from = row(catalog, station).from

      assert station_from.stop_id == "CEN"
      assert station_from.name == "Central Station"
      assert station_from.location_type == 1
      assert station_from.top_level == %{stop_id: "CEN", name: "Central Station"}
      assert station_from.child_count == 2
      assert row(catalog, platform).attention == []
      assert row(catalog, station).attention == []
    end

    test "annotates a stopless in-seat row with its trip selectors and no attention", ctx do
      in_seat =
        transfer(ctx, %{from_trip_id: "12-0815", to_trip_id: "24-0840", transfer_type: 4})

      catalog = load(ctx, view: :in_seat)
      annotated = row(catalog, in_seat)

      assert annotated.from.stop_id == nil
      assert annotated.from.name == nil
      assert annotated.from.location_type == nil
      assert annotated.from.platform_code == nil
      assert annotated.from.top_level == nil
      assert annotated.from.child_count == 0
      assert annotated.from.selector == {:trip, "12-0815"}
      assert annotated.to.selector == {:trip, "24-0840"}

      assert annotated.from.route == %{
               route_id: "12",
               route_short_name: "12",
               route_long_name: "Riverside"
             }

      assert annotated.attention == []
      assert annotated.competitor_ids == []
      assert annotated.reverse_id == nil
      assert annotated.transfer.transfer_type == 4
      assert annotated.transfer.from_trip_id == "12-0815"
    end
  end

  describe "attention reasons" do
    test "reports a to stop that is absent from the version", ctx do
      transfer(ctx, %{from_stop_id: "CEN-A", to_stop_id: "GHOST", transfer_type: 0})

      assert [annotated] = load(ctx).rows

      assert annotated.attention == [{:missing_stop, :to, "GHOST"}]
      assert annotated.competitor_ids == []
      assert annotated.to.stop_id == "GHOST"
      assert annotated.to.name == nil
      assert annotated.to.top_level == nil
      assert annotated.to.child_count == 0
    end

    test "reports a stop of a disallowed location type", ctx do
      transfer(ctx, %{from_stop_id: "CEN-E", to_stop_id: "HBR", transfer_type: 0})

      assert [annotated] = load(ctx).rows

      assert annotated.attention == [{:invalid_stop_type, :from, "CEN-E", 2}]
      assert annotated.from.name == "Central · Main entrance"
      assert annotated.from.location_type == 2
    end

    test "reports a route absent from the version", ctx do
      transfer(ctx, %{
        from_stop_id: "CEN-A",
        to_stop_id: "HBR",
        from_route_id: "R404",
        transfer_type: 0
      })

      assert [annotated] = load(ctx).rows

      assert annotated.attention == [{:missing_route, :from, "R404"}]
      assert annotated.from.selector == {:route, "R404"}
      assert annotated.from.route == nil
    end

    test "reports a trip absent from the version", ctx do
      transfer(ctx, %{
        from_stop_id: "CEN-A",
        to_stop_id: "HBR",
        to_trip_id: "T404",
        transfer_type: 0
      })

      assert [annotated] = load(ctx).rows

      assert annotated.attention == [{:missing_trip, :to, "T404"}]
      assert annotated.to.selector == {:trip, "T404"}
    end

    test "reports a trip that is not on the side's route", ctx do
      transfer(ctx, %{
        from_stop_id: "CEN-A",
        to_stop_id: "HBR",
        from_route_id: "24",
        from_trip_id: "12-0815",
        transfer_type: 0
      })

      assert [annotated] = load(ctx).rows

      assert annotated.attention == [{:trip_not_on_route, :from, "12-0815", "24"}]
    end

    test "reports a trip with no stop_time in the side's coverage", ctx do
      transfer(ctx, %{
        from_stop_id: "MUS",
        to_stop_id: "HBR",
        from_trip_id: "12-0815",
        transfer_type: 0
      })

      assert [annotated] = load(ctx).rows

      assert annotated.attention == [{:trip_not_at_stop, :from, "12-0815", "MUS"}]
    end

    test "reports a type 2 rule without a minimum time", ctx do
      transfer(ctx, %{from_stop_id: "CEN-A", to_stop_id: "CEN-C", transfer_type: 2})

      assert [annotated] = load(ctx).rows

      assert annotated.attention == [:min_time_missing]
      assert annotated.rank == 6
    end

    test "orders from-side reasons before to-side reasons and the minimum time last", ctx do
      transfer(ctx, %{
        from_stop_id: "CEN-A",
        to_stop_id: "MUS",
        from_route_id: "R404",
        to_trip_id: "T404",
        transfer_type: 2
      })

      assert [annotated] = load(ctx).rows

      assert annotated.attention == [
               {:missing_route, :from, "R404"},
               {:missing_trip, :to, "T404"},
               :min_time_missing
             ]
    end
  end

  describe "competitors" do
    test "flags two equally specific station rules that apply to one trip pair", ctx do
      from_route =
        transfer(ctx, %{
          from_stop_id: "CEN",
          to_stop_id: "CEN",
          from_route_id: "12",
          transfer_type: 2,
          min_transfer_time: 120
        })

      to_route =
        transfer(ctx, %{
          from_stop_id: "CEN",
          to_stop_id: "CEN",
          to_route_id: "24",
          transfer_type: 3
        })

      competing = load(ctx)

      assert row(competing, from_route).rank == 5
      assert row(competing, to_route).rank == 5
      assert row(competing, from_route).competitor_ids == [to_route.id]
      assert row(competing, to_route).competitor_ids == [from_route.id]
      assert row(competing, from_route).attention == [{:competes, 1}]
      assert row(competing, to_route).attention == [{:competes, 1}]

      shared =
        transfer(ctx, %{
          from_stop_id: "CEN",
          to_stop_id: "CEN",
          from_route_id: "12",
          to_route_id: "24",
          transfer_type: 2,
          min_transfer_time: 300
        })

      shadowed = load(ctx)

      assert row(shadowed, shared).rank == 4
      assert row(shadowed, shared).competitor_ids == []
      assert row(shadowed, shared).attention == []
      assert row(shadowed, from_route).competitor_ids == []
      assert row(shadowed, to_route).competitor_ids == []
      assert row(shadowed, from_route).attention == []
      assert row(shadowed, to_route).attention == []
    end

    test "derives competition from the stop_time incidence it loads", ctx do
      from_route =
        transfer(ctx, %{
          from_stop_id: "CEN",
          to_stop_id: "CEN",
          from_route_id: "12",
          transfer_type: 2,
          min_transfer_time: 120
        })

      to_route =
        transfer(ctx, %{
          from_stop_id: "CEN",
          to_stop_id: "CEN",
          to_route_id: "24",
          transfer_type: 3
        })

      assert row(load(ctx), from_route).competitor_ids == [to_route.id]

      Repo.delete_all(
        from(st in StopTime,
          where:
            st.organization_id == ^ctx.organization.id and
              st.gtfs_version_id == ^ctx.version.id and st.trip_id == "24-0840" and
              st.stop_id == "CEN-C"
        )
      )

      catalog = load(ctx)

      assert row(catalog, from_route).competitor_ids == []
      assert row(catalog, to_route).competitor_ids == []
      assert row(catalog, from_route).attention == []
      assert row(catalog, to_route).attention == []
    end
  end

  describe "reverse links" do
    test "links exact mirrors inside the same view", ctx do
      outbound =
        transfer(ctx, %{
          from_stop_id: "CEN-A",
          to_stop_id: "CEN-C",
          from_route_id: "12",
          to_route_id: "24",
          transfer_type: 0
        })

      inbound =
        transfer(ctx, %{
          from_stop_id: "CEN-C",
          to_stop_id: "CEN-A",
          from_route_id: "24",
          to_route_id: "12",
          transfer_type: 0
        })

      unmirrored = transfer(ctx, %{from_stop_id: "MKT", to_stop_id: "HBR", transfer_type: 1})

      general_trip =
        transfer(ctx, %{
          from_stop_id: "CEN-A",
          to_stop_id: "CEN-C",
          from_trip_id: "12-0815",
          to_trip_id: "24-0840",
          transfer_type: 0
        })

      in_seat_trip =
        transfer(ctx, %{
          from_stop_id: "CEN-C",
          to_stop_id: "CEN-A",
          from_trip_id: "24-0840",
          to_trip_id: "12-0815",
          transfer_type: 4
        })

      catalog = load(ctx)

      assert row(catalog, outbound).reverse_id == inbound.id
      assert row(catalog, inbound).reverse_id == outbound.id
      assert row(catalog, unmirrored).reverse_id == nil
      assert row(catalog, general_trip).reverse_id == nil

      in_seat_catalog = load(ctx, view: :in_seat)

      assert row(in_seat_catalog, in_seat_trip).reverse_id == nil
    end
  end

  describe "order and selection" do
    test "orders rows by from name, then to name, then id and selects the first row", ctx do
      from_route =
        transfer(ctx, %{
          from_stop_id: "CEN",
          to_stop_id: "CEN",
          from_route_id: "12",
          transfer_type: 2,
          min_transfer_time: 120
        })

      to_route =
        transfer(ctx, %{
          from_stop_id: "CEN",
          to_stop_id: "CEN",
          to_route_id: "24",
          transfer_type: 3
        })

      platform =
        transfer(ctx, %{from_stop_id: "CEN-A", to_stop_id: "CEN-C", transfer_type: 0})

      market = transfer(ctx, %{from_stop_id: "MKT", to_stop_id: "HBR", transfer_type: 1})

      catalog = load(ctx)
      ids = Enum.map(catalog.rows, & &1.id)

      assert ids |> Enum.take(2) |> Enum.sort() == sorted_ids([from_route, to_route])
      assert Enum.drop(ids, 2) == [platform.id, market.id]
      assert catalog.selected == hd(catalog.rows)
      assert catalog.selected.id in [from_route.id, to_route.id]
      assert catalog.selected.competitor_ids == [Enum.find(ids, &(&1 != catalog.selected.id))]

      assert catalog.competitors |> Enum.map(& &1.id) |> Enum.sort() ==
               catalog.selected.competitor_ids
    end
  end

  describe "query budget" do
    test "loads a version's catalog in a bounded number of queries that does not grow with the rule count",
         ctx do
      transfer(ctx, %{
        from_stop_id: "CEN-A",
        to_stop_id: "CEN-C",
        from_trip_id: "12-0815",
        to_trip_id: "24-0840",
        transfer_type: 0
      })

      transfer(ctx, %{from_stop_id: "CEN-A", to_stop_id: "HBR", transfer_type: 1})

      transfer(ctx, %{
        from_stop_id: "MKT",
        to_stop_id: "HBR",
        from_route_id: "12",
        transfer_type: 2,
        min_transfer_time: 120
      })

      assert load(ctx).total_count == 3
      small = query_count(fn -> load(ctx) end)

      for {from_stop_id, to_stop_id, from_route_id} <- [
            {"CEN-A", "HBR", "12"},
            {"CEN-A", "MKT", nil},
            {"CEN-A", "MKT", "6"},
            {"CEN-C", "HBR", nil},
            {"CEN-C", "MKT", nil},
            {"MKT", "CEN-A", nil},
            {"HBR", "CEN-A", nil},
            {"MKT", "MUS", nil},
            {"HBR", "MUS", nil}
          ] do
        transfer(ctx, %{
          from_stop_id: from_stop_id,
          to_stop_id: to_stop_id,
          from_route_id: from_route_id,
          transfer_type: 0
        })
      end

      large = query_count(fn -> load(ctx) end)

      assert load(ctx).total_count == 12
      assert small >= 1
      assert small <= 6
      assert large == small
    end
  end

  defp load(ctx, opts \\ []),
    do: Transfers.load_catalog(ctx.organization.id, ctx.version.id, opts)

  defp transfer(ctx, attrs), do: transfer_fixture(ctx.organization.id, ctx.version.id, attrs)

  defp row(catalog, transfer), do: Enum.find(catalog.rows, &(&1.id == transfer.id))

  defp row_ids(catalog), do: Enum.sort(Enum.map(catalog.rows, & &1.id))

  defp sorted_ids(transfers), do: Enum.sort(Enum.map(transfers, & &1.id))

  # Counts the catalog's own table queries while `fun` runs; an async neighbour's
  # query is ignored, `send/2` keeps the count in this process rather than in shared
  # state, and transaction statements without a source are not catalog queries.
  defp query_count(fun) do
    handler_id = "transfer-catalog-query-count-#{System.unique_integer([:positive])}"
    caller = self()

    :telemetry.attach(
      handler_id,
      @query_event,
      fn _event, _measurements, metadata, pid ->
        if self() == pid and metadata[:source] in @query_sources do
          send(pid, :query_counted)
        end
      end,
      caller
    )

    try do
      fun.()
    after
      :telemetry.detach(handler_id)
    end

    flush_query_count(0)
  end

  defp flush_query_count(count) do
    receive do
      :query_counted -> flush_query_count(count + 1)
    after
      0 -> count
    end
  end
end
