defmodule GtfsPlanner.Gtfs.Fares.WorkspaceTest do
  @moduledoc """
  Merge evidence (EV-11) for `Fares.load_workspace/2` and `Gtfs.load_fare_editor/3`,
  the read model the fare editor's four tabs share (AC-35, AC-39, AC-40).

  Every expected value is worked by hand from the fixtures in
  `test/fixtures/gtfs/fares` and from the spec, not read back from the code
  under test: the five single rides and two passes are the seven distinct
  `fare_product_name` values in `north_coast_v2/fare_products.txt`, the 3×3
  matrix is the three `areas.txt` areas in both directions, the three transfer
  policies are the three rows of `fare_transfer_rules.txt`, and the v1 counts are
  the rows of `north_coast_v1/fare_attributes.txt` and `fare_rules.txt`.

  The version enters rows through the production importer and is marked managed
  the way a conversion marks it, so every row read here was written by the same
  code path an operator's import writes.
  """
  use GtfsPlanner.DataCase, async: true

  import ExUnit.CaptureLog
  import GtfsPlanner.FaresFixtures, only: [import!: 3]
  import GtfsPlanner.OrganizationsFixtures, only: [organization_fixture: 1]
  import GtfsPlanner.VersionsFixtures, only: [gtfs_version_fixture: 1]

  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.CatalogReadAdapter
  alias GtfsPlanner.Gtfs.FareLegRule
  alias GtfsPlanner.Gtfs.FareProduct
  alias GtfsPlanner.Gtfs.FareProductDetail
  alias GtfsPlanner.Gtfs.Fares
  alias GtfsPlanner.Gtfs.Fares.Workspace
  alias GtfsPlanner.Gtfs.FareVersionSetting

  # The fixture's seven fare names: five single rides and two passes.
  @single_fares ["Local ride", "Valley ride", "Coast ride", "Valley-coast ride", "Intercity ride"]
  @pass_fares ["Day pass", "31-day pass"]

  @zones ~w(CST NPT TOL)

  setup do
    organization = organization_fixture(%{alias: "fares-workspace-#{unique_alias()}"})

    context = %{
      organization_id: organization.id,
      organization: organization
    }

    managed_version = gtfs_version_fixture(organization.id)
    import!(organization, managed_version, "north_coast_v2")
    mark_managed!(organization.id, managed_version.id)
    record_product_kinds!(organization.id, managed_version.id)

    Map.put(context, :version, managed_version)
  end

  describe "the managed North Coast version" do
    test "reads seven fares, four riders and the Local ride's app prices", context do
      {:ok, workspace} = load(context)

      assert %Workspace{managed?: true, older_format: "derived", currency: "USD"} = workspace

      assert Enum.map(workspace.fares, & &1.name) == [
               "Coast ride",
               "Intercity ride",
               "Local ride",
               "Valley ride",
               "Valley-coast ride",
               "31-day pass",
               "Day pass"
             ]

      assert Enum.map(workspace.fares, & &1.kind) == [
               "single",
               "single",
               "single",
               "single",
               "single",
               "pass",
               "pass"
             ]

      assert fare(workspace, "Local ride").prices == %{
               "adult" => Decimal.new("1.50"),
               "child" => Decimal.new("0.00"),
               "reduced" => Decimal.new("0.75"),
               "youth" => Decimal.new("1.00")
             }

      # The app is sold at its own prices, so it is the fare's one differing
      # medium; cash is the base and is the fare's own row.
      assert fare(workspace, "Local ride").media_prices == %{
               "app" => %{
                 "adult" => Decimal.new("1.25"),
                 "child" => Decimal.new("0.00"),
                 "reduced" => Decimal.new("0.60"),
                 "youth" => Decimal.new("0.75")
               }
             }

      assert fare(workspace, "Local ride").media == ["app", "cash"]

      # A rider the pass is not sold to holds no price, which is not free.
      assert fare(workspace, "Day pass").prices["child"] == nil

      assert Enum.map(workspace.riders, & &1.rider_category_id) ==
               ["adult", "child", "reduced", "youth"]

      assert workspace.riders
             |> Enum.find(&(&1.rider_category_id == "adult"))
             |> Map.fetch!(:default?)

      assert Enum.map(workspace.media, & &1.fare_media_id) == ["cash", "app"]

      assert Enum.all?(@single_fares, &Enum.any?(workspace.fares, fn fare -> fare.name == &1 end))

      assert Enum.all?(@pass_fares, &(fare(workspace, &1).kind == "pass"))
    end

    test "reads two route groups and one gap-free 3×3 zone matrix", context do
      {:ok, workspace} = load(context)

      assert Enum.map(workspace.groups, & &1.network_id) == ["N_INTERCITY", "N_LOCAL"]

      assert workspace.groups
             |> Enum.find(&(&1.network_id == "N_LOCAL"))
             |> Map.fetch!(:route_ids) ==
               ~w(1 11 12 2 20 21 3 30 4 40 5 6 7)

      assert Enum.map(workspace.groups, & &1.zone_priced?) == [false, true]

      assert [%{network_id: "N_LOCAL", zones: zones, cells: cells}] = workspace.matrices

      assert Enum.map(zones, & &1.area_id) == @zones
      assert map_size(cells) == 9
      assert Enum.all?(cells, fn {_pair, cell} -> cell.gap? == false end)

      # The fixture sells one fare per zone pair, one product row per rider, so a
      # cell names the four rows of that fare.
      assert cells[{"NPT", "NPT"}].products == [
               "local_ride_adult_cash",
               "local_ride_child_cash",
               "local_ride_reduced_cash",
               "local_ride_youth_cash"
             ]

      assert cells[{"NPT", "TOL"}].products == [
               "valley_ride_adult_cash",
               "valley_ride_child_cash",
               "valley_ride_reduced_cash",
               "valley_ride_youth_cash"
             ]

      assert cells[{"TOL", "CST"}].products == [
               "valley_coast_ride_adult_cash",
               "valley_coast_ride_child_cash",
               "valley_coast_ride_reduced_cash",
               "valley_coast_ride_youth_cash"
             ]
    end

    test "reads three transfer policies and no leg join rules", context do
      {:ok, workspace} = load(context)

      policies =
        workspace.transfers
        |> Enum.map(fn cell -> {cell.from_leg_group_id, cell.to_leg_group_id, cell.policy} end)
        |> Enum.reject(fn {_from, _to, policy} -> is_nil(policy) end)

      assert length(policies) == 3

      assert {_, _, %{pay: :free, minutes: 90, count: 2}} =
               find_transfer(workspace, "LG_LOCAL", "LG_LOCAL")

      assert {_, _, %{pay: :difference, minutes: 90, count: nil}} =
               find_transfer(workspace, "LG_LOCAL", "LG_INTERCITY")

      assert {_, _, %{pay: :free, minutes: 90, count: nil}} =
               find_transfer(workspace, "LG_INTERCITY", "LG_LOCAL")

      assert workspace.joins == []
    end

    test "reads the version's currency and no time periods", context do
      {:ok, workspace} = load(context)

      assert workspace.currency == "USD"
      assert workspace.time_periods == []
    end
  end

  describe "a fare's cells and rules" do
    test "name every `fare_products` row the fare is written from", context do
      {:ok, workspace} = load(context)

      fare = Enum.find(workspace.fares, &(&1.name == "Local ride"))

      # Local ride is sold to four rider types and priced differently on the
      # app, so it is eight rows: the four the grid shows on its own row, and
      # the four it prices on a second payment method.
      assert length(fare.cells) == 8
      assert fare.base_media_id == "cash"
      assert Enum.all?(fare.cells, &is_binary(&1.fare_product_id))

      assert [adult_cash] =
               Enum.filter(
                 fare.cells,
                 &(&1.rider_category_id == "adult" and &1.fare_media_id == "cash")
               )

      assert adult_cash.fare_product_id == "local_ride_adult_cash"
    end

    test "carry the charging rule that makes a fare a single ride", context do
      {:ok, workspace} = load(context)

      ride = Enum.find(workspace.fares, &(&1.name == "Local ride"))
      assert ride.kind == "single"
      # The three same-area charging rules `fare_leg_rules.txt` holds for the
      # ride: the same network in, the same area out.
      assert Enum.map(ride.rules, &{&1.network_id, &1.from_area_id, &1.to_area_id}) == [
               {"N_LOCAL", "CST", "CST"},
               {"N_LOCAL", "NPT", "NPT"},
               {"N_LOCAL", "TOL", "TOL"}
             ]

      assert Enum.all?(ride.rules, &(is_binary(&1.id) and &1.product_ids != []))
      assert Enum.all?(ride.rules, &is_nil(&1.from_timeframe_group_id))

      # A pass names a network but no fare area at all: its leg rules stand in
      # for other fares rather than charge a ride, which is why the older format
      # has no row for it. The rule is still reported, because it is the reason.
      pass = Enum.find(workspace.fares, &(&1.name == "Day pass"))
      assert pass.kind == "pass"
      assert [%{network_id: "N_LOCAL", from_area_id: nil, to_area_id: nil}] = pass.rules
      assert hd(pass.rules).product_ids != []
    end
  end

  describe "pass rows" do
    test "never appear as a matrix cell, even when they name both areas", context do
      # A pass rule naming a zone pair is what the managed form produces: a pass
      # mirrors the single-ride rows of the cell it is accepted on. It still
      # prices no cell.
      insert_pass_rule!(context, "day_pass_adult_cash", "NPT", "TOL")
      insert_pass_rule!(context, "day_pass_adult_cash", "NPT", "NPT")

      {:ok, workspace} = load(context)

      cells = workspace.matrices |> hd() |> Map.fetch!(:cells)

      products = cells |> Map.values() |> Enum.flat_map(& &1.products)

      assert map_size(cells) == 9
      assert Enum.all?(cells, fn {_pair, cell} -> cell.gap? == false end)

      # The pass rules added above land in the cells they name, and the
      # single-ride rows are still the only products there.
      assert cells[{"NPT", "TOL"}].products == [
               "valley_ride_adult_cash",
               "valley_ride_child_cash",
               "valley_ride_reduced_cash",
               "valley_ride_youth_cash"
             ]

      assert cells[{"NPT", "NPT"}].products == [
               "local_ride_adult_cash",
               "local_ride_child_cash",
               "local_ride_reduced_cash",
               "local_ride_youth_cash"
             ]

      assert map_size(cells) == 9
      assert Enum.all?(cells, fn {_pair, cell} -> cell.gap? == false end)

      refute Enum.any?(products, &(&1 in ["day_pass_adult_cash", "month_pass_adult_app"]))

      # Every product in every cell is one of the fixture's four single-ride
      # fares, one product row per rider — no pass anywhere.
      assert length(Enum.uniq(products)) == 16

      assert products
             |> Enum.map(fn product -> product |> String.split("_") |> Enum.take(2) end)
             |> Enum.uniq()
             |> Enum.sort() ==
               [["coast", "ride"], ["local", "ride"], ["valley", "coast"], ["valley", "ride"]]
    end
  end

  describe "another version's rows" do
    test "are absent from the workspace", context do
      other_version = gtfs_version_fixture(context.organization_id)
      import!(context.organization, other_version, "north_coast_v1")

      {:ok, workspace} = load(context)

      # The v1 version's five fares and three riders would change these counts.
      assert length(workspace.fares) == 7
      assert length(workspace.riders) == 4
      assert length(workspace.groups) == 2
      assert workspace.unmanaged == nil
      refute Enum.any?(workspace.fares, &(&1.name == "LOCAL"))
      assert workspace.matrices |> hd() |> Map.fetch!(:network_id) == "N_LOCAL"
    end

    test "are absent even when the other version is managed", context do
      other_version = gtfs_version_fixture(context.organization_id)
      import!(context.organization, other_version, "north_coast_v2")
      mark_managed!(context.organization_id, other_version.id)
      record_product_kinds!(context.organization_id, other_version.id)

      {:ok, workspace} = load(context)

      assert workspace.managed?
      assert length(workspace.fares) == 7
      assert length(workspace.matrices) == 1
    end
  end

  describe "the catalog read adapter" do
    test "answers {:error, :unavailable} when the database is unreachable", context do
      capture_log(fn ->
        with_unreachable_repo(fn ->
          assert CatalogReadAdapter.Repo.load_fare_editor(
                   context.organization_id,
                   context.version.id,
                   []
                 ) == {:error, :unavailable}
        end)
      end)
    end

    test "answers the workspace through Gtfs.load_fare_editor/3", context do
      assert {:ok, %Workspace{managed?: true}} =
               Gtfs.load_fare_editor(context.organization_id, context.version.id, [])
    end
  end

  describe "an unmanaged v1 version" do
    test "reports managed? false and its stored rows", context do
      version = gtfs_version_fixture(context.organization_id)
      import!(context.organization, version, "north_coast_v1")

      {:ok, workspace} =
        Fares.load_workspace(context.organization_id, version.id)

      assert %Workspace{managed?: false, older_format: nil, unmanaged: unmanaged} = workspace
      assert unmanaged.format == :v1

      assert unmanaged.counts[:fare_attributes] == 5
      assert unmanaged.counts[:fare_rules] == 11
      assert unmanaged.counts[:fare_products] == 0
      assert unmanaged.counts[:rider_categories] == 0
      assert unmanaged.counts[:fare_leg_rules] == 0

      assert Enum.map(unmanaged.attributes, & &1.fare_id) ==
               ~w(LOCAL VALLEY COAST VALCOAST INTERCITY)

      assert unmanaged.attributes |> hd() |> Map.fetch!(:price) == Decimal.new("1.50")
    end

    test "a managed version carries no stored-row summary", context do
      {:ok, workspace} = load(context)

      assert workspace.unmanaged == nil
    end
  end

  defp load(context), do: Fares.load_workspace(context.organization_id, context.version.id)

  defp fare(workspace, name) do
    Enum.find(workspace.fares, &(&1.name == name)) || flunk("no fare named #{name}")
  end

  defp find_transfer(workspace, from, to) do
    cell =
      Enum.find(workspace.transfers, fn cell ->
        cell.from_leg_group_id == from and cell.to_leg_group_id == to
      end) || flunk("no transfer cell #{from} to #{to}")

    {cell.from_leg_group_id, cell.to_leg_group_id, cell.policy}
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

  # The product kinds and positions the editor's writers would have recorded: the
  # two pass names are passes, and the Day pass is accepted on the Local network.
  defp record_product_kinds!(organization_id, gtfs_version_id) do
    rows =
      Ecto.Query.from(product in FareProduct,
        where:
          product.organization_id == ^organization_id and
            product.gtfs_version_id == ^gtfs_version_id
      )
      |> Repo.all()

    for product <- rows do
      base = product.fare_product_id |> String.split("_adult_") |> hd()

      kind =
        cond do
          String.starts_with?(base, "day_pass") -> "pass"
          String.starts_with?(base, "month_pass") -> "pass"
          true -> "single"
        end

      accepted = if base == "day_pass", do: ["N_LOCAL"], else: []

      {:ok, _detail} =
        %FareProductDetail{}
        |> Ecto.Changeset.change(%{
          organization_id: organization_id,
          gtfs_version_id: gtfs_version_id,
          fare_product_id: product.fare_product_id,
          kind: kind,
          position: 0,
          accepted_network_ids: accepted
        })
        |> Repo.insert()
    end
  end

  defp insert_pass_rule!(context, fare_product_id, from_area_id, to_area_id) do
    now = DateTime.utc_now()

    Repo.insert_all(FareLegRule, [
      %{
        id: Ecto.UUID.generate(),
        organization_id: context.organization_id,
        gtfs_version_id: context.version.id,
        leg_group_id: "N_LOCAL",
        network_id: "N_LOCAL",
        from_area_id: from_area_id,
        to_area_id: to_area_id,
        from_timeframe_group_id: nil,
        to_timeframe_group_id: nil,
        fare_product_id: fare_product_id,
        rule_priority: nil,
        inserted_at: now,
        updated_at: now
      }
    ])
  end

  defp unique_alias do
    "s29-#{System.unique_integer([:positive, :monotonic])}"
  end

  # Points the calling process at a real but unreachable Postgres pool, so every
  # checkout is dropped from the queue with a DBConnection.ConnectionError — the
  # one failure the read adapter reports as `{:error, :unavailable}`.
  defp with_unreachable_repo(fun) do
    {:ok, pid} =
      GtfsPlanner.Repo.start_link(
        name: nil,
        hostname: "127.0.0.1",
        port: 1,
        username: "postgres",
        password: "postgres",
        database: "gtfs_planner_unreachable",
        pool: DBConnection.ConnectionPool,
        pool_size: 1,
        queue_target: 20,
        queue_interval: 20,
        connect_timeout: 100,
        log: false
      )

    previous = GtfsPlanner.Repo.get_dynamic_repo()
    GtfsPlanner.Repo.put_dynamic_repo(pid)

    try do
      fun.()
    after
      GtfsPlanner.Repo.put_dynamic_repo(previous)
      Supervisor.stop(pid)
    end
  end
end
