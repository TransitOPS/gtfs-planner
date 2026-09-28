defmodule GtfsPlanner.Gtfs.Transfers.CatalogListingTest do
  @moduledoc """
  Merge evidence (EV-5) for the catalog's filters, search, sort, pagination, rule
  selection, filter options and related counts.

  `Transfers.load_catalog/3` must narrow the loaded view with typed options and
  return exactly the contract's page: a station filter matching its children, a
  route filter matching a selected trip's route, a type only inside its view's
  range, the general view's attention filter, a case-insensitive search over the
  documented fields, a stable sort whose ties stay ascending in both directions,
  a clamped page, the requested rule's own page and selection, and filter options
  that describe the view plus the applied value. `Transfers.count_general/3` must
  use the same stop and route predicates over the general rows without loading
  incidence.

  The cases use the shared literal network (`TransfersFixtures`) and assert
  literal orders, pages and counts, so a station filter that misses children, a
  route filter that misses a selected trip's route, an invalid value that raises,
  ties that reorder between loads, a page that is not clamped, a rule selection on
  the wrong page, or a count whose predicate disagrees with the list is rejected
  here. EV-5 does not prove URL canonicalization or the rendered list, which
  EV-16 and EV-17 own.
  """
  use GtfsPlanner.DataCase, async: true

  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Gtfs.Stop
  alias GtfsPlanner.Gtfs.Transfer
  alias GtfsPlanner.Gtfs.Transfers
  alias GtfsPlanner.Repo
  alias GtfsPlanner.TransfersFixtures

  @query_event [:gtfs_planner, :repo, :query]
  @query_sources ~w(transfers stops trips routes stop_times)

  setup do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    TransfersFixtures.transfer_network_fixture(organization.id, version.id)

    %{organization: organization, version: version}
  end

  describe "stop filter" do
    test "a station matches its children while a platform matches only its own rules", ctx do
      platform = transfer(ctx, %{from_stop_id: "CEN-A", to_stop_id: "HBR", transfer_type: 0})
      child = transfer(ctx, %{from_stop_id: "MKT", to_stop_id: "CEN-C", transfer_type: 0})
      station = transfer(ctx, %{from_stop_id: "CEN", to_stop_id: "CEN", transfer_type: 0})
      entrance = transfer(ctx, %{from_stop_id: "MUS", to_stop_id: "CEN-E", transfer_type: 0})
      elsewhere = transfer(ctx, %{from_stop_id: "MKT", to_stop_id: "MUS", transfer_type: 1})

      catalog = load(ctx, stop: "CEN")

      assert row_ids(catalog) == sorted_ids([platform, child, station, entrance])
      assert catalog.total_count == 4
      refute elsewhere.id in ids(catalog)

      assert ids(load(ctx, stop: "CEN-A")) == [platform.id]
      assert ids(load(ctx, stop: "UNKNOWN")) == []
    end

    test "matches a stored stop the version does not contain", ctx do
      dangling = transfer(ctx, %{from_stop_id: "GHOST", to_stop_id: "HBR", transfer_type: 0})
      transfer(ctx, %{from_stop_id: "MKT", to_stop_id: "HBR", transfer_type: 1})

      assert ids(load(ctx, stop: "GHOST")) == [dangling.id]
    end
  end

  describe "route filter" do
    test "matches a route selector and the route of a selected trip", ctx do
      route_pair =
        transfer(ctx, %{
          from_stop_id: "MKT",
          to_stop_id: "HBR",
          from_route_id: "24",
          transfer_type: 0
        })

      trip_pair =
        transfer(ctx, %{
          from_stop_id: "MKT",
          to_stop_id: "HBR",
          from_trip_id: "24-0840",
          transfer_type: 0
        })

      other =
        transfer(ctx, %{
          from_stop_id: "MUS",
          to_stop_id: "HBR",
          from_route_id: "12",
          transfer_type: 0
        })

      other_trip =
        transfer(ctx, %{
          from_stop_id: "MUS",
          to_stop_id: "MKT",
          from_trip_id: "12-0815",
          transfer_type: 0
        })

      catalog = load(ctx, route: "24")

      assert row_ids(catalog) == sorted_ids([route_pair, trip_pair])
      assert catalog.total_count == 2

      assert row_ids(load(ctx, route: "12")) == sorted_ids([other, other_trip])
      assert ids(load(ctx, route: "99")) == []
      assert ids(load(ctx, route: "R404")) == []
    end
  end

  describe "type and attention filters" do
    test "filters by the type of the view being listed", ctx do
      type0 = transfer(ctx, %{from_stop_id: "MKT", to_stop_id: "HBR", transfer_type: 0})
      type1 = transfer(ctx, %{from_stop_id: "MKT", to_stop_id: "MUS", transfer_type: 1})

      type2 =
        transfer(ctx, %{
          from_stop_id: "MKT",
          to_stop_id: "NOC",
          transfer_type: 2,
          min_transfer_time: 120
        })

      type3 = transfer(ctx, %{from_stop_id: "CEN-A", to_stop_id: "HBR", transfer_type: 3})

      seat4 =
        transfer(ctx, %{from_trip_id: "12-0815", to_trip_id: "24-0840", transfer_type: 4})

      seat5 =
        transfer(ctx, %{from_trip_id: "12-1010", to_trip_id: "24-0920", transfer_type: 5})

      assert ids(load(ctx, type: 2)) == [type2.id]

      general = load(ctx, type: 4)

      assert row_ids(general) == sorted_ids([type0, type1, type2, type3])
      assert general.total_count == 4
      assert row_ids(load(ctx, type: "2")) == sorted_ids([type0, type1, type2, type3])

      assert ids(load(ctx, view: :in_seat, type: 4)) == [seat4.id]
      assert row_ids(load(ctx, view: :in_seat, type: 2)) == sorted_ids([seat4, seat5])
    end

    test "keeps only rows with an attention reason in the general view", ctx do
      missing_time = transfer(ctx, %{from_stop_id: "MKT", to_stop_id: "HBR", transfer_type: 2})
      clean = transfer(ctx, %{from_stop_id: "MKT", to_stop_id: "MUS", transfer_type: 1})

      seat =
        transfer(ctx, %{from_trip_id: "12-0815", to_trip_id: "24-0840", transfer_type: 4})

      assert ids(load(ctx, attention: true)) == [missing_time.id]
      assert row_ids(load(ctx, attention: false)) == sorted_ids([missing_time, clean])
      assert ids(load(ctx, attention: true, type: 0)) == []
      assert ids(load(ctx, view: :in_seat, attention: true)) == [seat.id]
    end
  end

  describe "search" do
    test "matches the documented fields case-insensitively", ctx do
      set_platform_code(ctx, "MKT", "DOCK-9")

      by_name = transfer(ctx, %{from_stop_id: "MUS", to_stop_id: "HBR", transfer_type: 0})
      by_stop_id = transfer(ctx, %{from_stop_id: "NOC", to_stop_id: "HBR", transfer_type: 0})

      by_platform =
        transfer(ctx, %{
          from_stop_id: "MKT",
          to_stop_id: "HBR",
          from_route_id: "99",
          transfer_type: 0
        })

      by_parent = transfer(ctx, %{from_stop_id: "CEN-A", to_stop_id: "HBR", transfer_type: 0})

      # The route and trip rows name HBR, not MKT: MKT carries the DOCK-9 platform
      # code above, so any row naming it would match "dock-9" too.
      by_route =
        transfer(ctx, %{
          from_stop_id: "HBR",
          to_stop_id: "HBR",
          from_route_id: "12",
          transfer_type: 0
        })

      by_trip =
        transfer(ctx, %{
          from_stop_id: "HBR",
          to_stop_id: "HBR",
          from_trip_id: "24-0840",
          transfer_type: 0
        })

      assert ids(load(ctx, search: "museum")) == [by_name.id]
      assert ids(load(ctx, search: "MUSEUM")) == [by_name.id]
      assert ids(load(ctx, search: "noc")) == [by_stop_id.id]
      assert ids(load(ctx, search: "dock-9")) == [by_platform.id]
      assert ids(load(ctx, search: "Central Station")) == [by_parent.id]
      assert ids(load(ctx, search: "riverside")) == [by_route.id]
      assert ids(load(ctx, search: "99")) == [by_platform.id]
      assert ids(load(ctx, search: "24-0840")) == [by_trip.id]
      assert ids(load(ctx, search: "zzz")) == []
    end

    test "combines search with the filters using AND", ctx do
      museum = transfer(ctx, %{from_stop_id: "MUS", to_stop_id: "HBR", transfer_type: 0})

      market =
        transfer(ctx, %{
          from_stop_id: "MKT",
          to_stop_id: "HBR",
          from_route_id: "12",
          transfer_type: 1
        })

      route24 =
        transfer(ctx, %{
          from_stop_id: "MKT",
          to_stop_id: "NOC",
          from_route_id: "24",
          transfer_type: 0
        })

      assert ids(load(ctx, search: "museum", stop: "MUS")) == [museum.id]

      # NOC is route24's to-stop only, so an empty result needs the search and the
      # stop filter together.
      assert ids(load(ctx, search: "museum", stop: "NOC")) == []
      assert ids(load(ctx, search: "riverside", type: 1)) == [market.id]
      assert ids(load(ctx, search: "riverside", route: "24")) == []
      assert ids(load(ctx, stop: "MKT", route: "24")) == [route24.id]
    end
  end

  describe "sort" do
    test "orders by from and to, reversing only the primary key", ctx do
      museum =
        transfer(ctx, %{
          from_stop_id: "MKT",
          to_stop_id: "MUS",
          from_route_id: "6",
          transfer_type: 0
        })

      harbor_a =
        transfer(ctx, %{
          from_stop_id: "MKT",
          to_stop_id: "HBR",
          from_route_id: "12",
          transfer_type: 0
        })

      harbor_b =
        transfer(ctx, %{
          from_stop_id: "MKT",
          to_stop_id: "HBR",
          from_route_id: "24",
          transfer_type: 0
        })

      central = transfer(ctx, %{from_stop_id: "CEN-A", to_stop_id: "HBR", transfer_type: 0})

      [first, second] = Enum.sort_by([harbor_a, harbor_b], & &1.id)

      assert ids(load(ctx, sort_by: :from, sort_dir: :asc)) ==
               [central.id, first.id, second.id, museum.id]

      assert ids(load(ctx, sort_by: :from, sort_dir: :desc)) ==
               [first.id, second.id, museum.id, central.id]

      assert ids(load(ctx, sort_by: :to, sort_dir: :asc)) ==
               [central.id, first.id, second.id, museum.id]

      assert ids(load(ctx, sort_by: :to, sort_dir: :desc)) ==
               [museum.id, central.id, first.id, second.id]
    end

    test "orders by type and minimum time, nil before a number when ascending", ctx do
      type0 =
        transfer(ctx, %{
          from_stop_id: "MKT",
          to_stop_id: "HBR",
          from_route_id: "12",
          transfer_type: 0
        })

      type1 = transfer(ctx, %{from_stop_id: "NOC", to_stop_id: "HBR", transfer_type: 1})

      type2_late =
        transfer(ctx, %{
          from_stop_id: "MKT",
          to_stop_id: "MUS",
          from_route_id: "6",
          transfer_type: 2,
          min_transfer_time: 120
        })

      type2_early =
        transfer(ctx, %{
          from_stop_id: "CEN-A",
          to_stop_id: "MUS",
          from_route_id: "6",
          transfer_type: 2,
          min_transfer_time: 0
        })

      type3 =
        transfer(ctx, %{
          from_stop_id: "CEN-A",
          to_stop_id: "HBR",
          from_route_id: "24",
          transfer_type: 3
        })

      assert ids(load(ctx, sort_by: :type, sort_dir: :asc)) ==
               [type0.id, type1.id, type2_early.id, type2_late.id, type3.id]

      assert ids(load(ctx, sort_by: :type, sort_dir: :desc)) ==
               [type3.id, type2_early.id, type2_late.id, type1.id, type0.id]

      assert ids(load(ctx, sort_by: :min_time, sort_dir: :asc)) ==
               [type3.id, type0.id, type1.id, type2_early.id, type2_late.id]

      assert ids(load(ctx, sort_by: :min_time, sort_dir: :desc)) ==
               [type2_late.id, type2_early.id, type3.id, type0.id, type1.id]
    end
  end

  describe "pagination and selection" do
    test "paginates the filtered list, clamps the page and opens the rule's page", ctx do
      entrance = transfer(ctx, %{from_stop_id: "CEN-E", to_stop_id: "HBR", transfer_type: 0})
      harbor = transfer(ctx, %{from_stop_id: "HBR", to_stop_id: "MKT", transfer_type: 0})
      market = transfer(ctx, %{from_stop_id: "MKT", to_stop_id: "HBR", transfer_type: 0})
      museum = transfer(ctx, %{from_stop_id: "MUS", to_stop_id: "HBR", transfer_type: 0})
      nowhere = transfer(ctx, %{from_stop_id: "NOC", to_stop_id: "HBR", transfer_type: 0})

      assert ids(load(ctx)) == [entrance.id, harbor.id, market.id, museum.id, nowhere.id]

      first = load(ctx, per_page: 2)

      assert first.total_count == 5
      assert first.page == 1
      assert first.per_page == 2
      assert length(first.rows) == 2
      assert first.counts == %{general: 5, in_seat: 0}
      assert ids(first) == [entrance.id, harbor.id]

      assert load(ctx, per_page: 2, page: 3).page == 3
      assert ids(load(ctx, per_page: 2, page: 3)) == [nowhere.id]

      clamped = load(ctx, per_page: 2, page: 9)

      assert clamped.page == 3
      assert ids(clamped) == [nowhere.id]

      assert load(ctx, per_page: 2, page: 0).page == 1
      assert load(ctx, per_page: 2, page: nil).page == 1
      assert ids(load(ctx, per_page: 2, page: 0)) == [entrance.id, harbor.id]

      selected = load(ctx, per_page: 2, rule: museum.id)

      assert selected.page == 2
      assert ids(selected) == [market.id, museum.id]
      assert selected.selected.id == museum.id

      last = load(ctx, per_page: 2, rule: nowhere.id)

      assert last.page == 3
      assert last.selected.id == nowhere.id

      unknown = load(ctx, per_page: 2, rule: Ecto.UUID.generate())

      assert unknown.page == 1
      assert unknown.selected.id == entrance.id
    end

    test "a filtered read changes no stored row", ctx do
      transfer(ctx, %{
        from_stop_id: "MKT",
        to_stop_id: "HBR",
        from_route_id: "12",
        transfer_type: 0
      })

      stored = Repo.aggregate(Transfer, :count)

      load(ctx, stop: "MKT", search: "harbor", per_page: 1, page: 2, rule: Ecto.UUID.generate())
      Transfers.count_general(ctx.organization.id, ctx.version.id, stop: "MKT")

      assert Repo.aggregate(Transfer, :count) == stored
    end
  end

  describe "filter options" do
    test "describes the view's own locations and routes and appends the applied value", ctx do
      at_child = transfer(ctx, %{from_stop_id: "CEN-A", to_stop_id: "MKT", transfer_type: 0})

      at_market =
        transfer(ctx, %{
          from_stop_id: "MKT",
          to_stop_id: "HBR",
          from_route_id: "12",
          transfer_type: 0
        })

      at_harbor = transfer(ctx, %{from_stop_id: "HBR", to_stop_id: "MUS", transfer_type: 0})

      seat =
        transfer(ctx, %{from_trip_id: "12-0815", to_trip_id: "24-0840", transfer_type: 4})

      general = load(ctx)

      assert row_ids(general) == sorted_ids([at_child, at_market, at_harbor])

      assert general.filter_options.stops == [
               %{stop_id: "CEN", name: "Central Station"},
               %{stop_id: "HBR", name: "Harbor"},
               %{stop_id: "MKT", name: "Market Street"},
               %{stop_id: "MUS", name: "Museum"}
             ]

      assert general.filter_options.routes == [
               %{route_id: "12", route_short_name: "12", route_long_name: "Riverside"}
             ]

      assert general.filter_options.types == [0, 1, 2, 3]

      filtered = load(ctx, stop: "CEN-A")

      assert ids(filtered) == [at_child.id]

      assert filtered.filter_options.stops ==
               general.filter_options.stops ++ [%{stop_id: "CEN-A", name: nil}]

      missing_route = load(ctx, route: "R404")

      assert missing_route.rows == []

      assert missing_route.filter_options.routes ==
               general.filter_options.routes ++
                 [%{route_id: "R404", route_short_name: nil, route_long_name: nil}]

      in_seat = load(ctx, view: :in_seat)

      assert ids(in_seat) == [seat.id]
      assert in_seat.filter_options.stops == []

      assert in_seat.filter_options.routes == [
               %{route_id: "12", route_short_name: "12", route_long_name: "Riverside"},
               %{route_id: "24", route_short_name: "24", route_long_name: "Harbor"}
             ]

      assert in_seat.filter_options.types == [4, 5]
    end
  end

  describe "count_general" do
    test "counts the same rows the filtered list returns and ignores in-seat rows", ctx do
      transfer(ctx, %{from_stop_id: "CEN-A", to_stop_id: "HBR", transfer_type: 0})
      transfer(ctx, %{from_stop_id: "MKT", to_stop_id: "CEN-C", transfer_type: 1})

      transfer(ctx, %{
        from_stop_id: "MKT",
        to_stop_id: "MUS",
        from_route_id: "24",
        transfer_type: 0
      })

      transfer(ctx, %{
        from_stop_id: "NOC",
        to_stop_id: "HBR",
        from_trip_id: "24-0840",
        transfer_type: 2,
        min_transfer_time: 300
      })

      transfer(ctx, %{
        from_stop_id: "CEN-A",
        to_stop_id: "HBR",
        from_trip_id: "12-0815",
        to_trip_id: "24-0840",
        transfer_type: 4
      })

      for opts <- [[stop: "CEN"], [stop: "CEN-A"], [stop: "HBR"], [route: "24"]] do
        assert count_general(ctx, opts) == load(ctx, opts).total_count
      end

      assert count_general(ctx, stop: "CEN") == 2
      assert count_general(ctx, stop: "CEN-A") == 1
      assert count_general(ctx, route: "24") == 2
      assert count_general(ctx, stop: "UNKNOWN") == 0
      assert count_general(ctx, route: "R404") == 0
    end

    test "counts without loading incidence", ctx do
      transfer(ctx, %{
        from_stop_id: "MKT",
        to_stop_id: "HBR",
        from_route_id: "12",
        transfer_type: 0
      })

      transfer(ctx, %{
        from_stop_id: "MKT",
        to_stop_id: "MUS",
        from_trip_id: "24-0840",
        transfer_type: 0
      })

      transfer(ctx, %{from_stop_id: "CEN-A", to_stop_id: "HBR", transfer_type: 0})

      assert count_general(ctx, route: "12") == 1
      assert count_general(ctx, stop: "CEN") == 1

      assert query_sources(fn -> count_general(ctx, route: "12") end) ==
               MapSet.new(["transfers", "trips"])

      assert query_sources(fn -> count_general(ctx, stop: "CEN") end) ==
               MapSet.new(["transfers", "stops"])
    end
  end

  defp load(ctx, opts \\ []),
    do: Transfers.load_catalog(ctx.organization.id, ctx.version.id, opts)

  defp count_general(ctx, opts),
    do: Transfers.count_general(ctx.organization.id, ctx.version.id, opts)

  defp transfer(ctx, attrs), do: transfer_fixture(ctx.organization.id, ctx.version.id, attrs)

  defp ids(catalog), do: Enum.map(catalog.rows, & &1.id)

  defp row_ids(catalog), do: catalog |> ids() |> Enum.sort()

  defp sorted_ids(transfers), do: transfers |> Enum.map(& &1.id) |> Enum.sort()

  defp set_platform_code(ctx, stop_id, platform_code) do
    Repo.update_all(
      from(s in Stop,
        where:
          s.organization_id == ^ctx.organization.id and
            s.gtfs_version_id == ^ctx.version.id and s.stop_id == ^stop_id
      ),
      set: [platform_code: platform_code]
    )
  end

  # Collects the table sources of the queries `fun` issues in this process, so a
  # count that loads incidence would show `stop_times` here. Transaction statements
  # have no source and are ignored; an async neighbour's query belongs to its own
  # process and is ignored too.
  defp query_sources(fun) do
    handler_id = "transfer-count-query-sources-#{System.unique_integer([:positive])}"
    caller = self()

    :telemetry.attach(
      handler_id,
      @query_event,
      fn _event, _measurements, metadata, pid ->
        if self() == pid and metadata[:source] in @query_sources do
          send(pid, {:query_source, metadata[:source]})
        end
      end,
      caller
    )

    try do
      fun.()
    after
      :telemetry.detach(handler_id)
    end

    flush_sources(MapSet.new())
  end

  defp flush_sources(sources) do
    receive do
      {:query_source, source} -> flush_sources(MapSet.put(sources, source))
    after
      0 -> sources
    end
  end
end
