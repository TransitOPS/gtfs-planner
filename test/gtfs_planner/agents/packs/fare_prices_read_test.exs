defmodule GtfsPlanner.Agents.Packs.FarePricesReadTest do
  @moduledoc """
  Merge evidence (EV-13) for the Fare price pack's `list_price_cells` through the
  real composition (`Agents.open/1` -> `Session` -> `Turn` -> `Dispatch` -> pack ->
  `Fares.list_price_cells/3`), with only the OpenRouter HTTP boundary doubled.

  Expected cells are literal values read from the `north_coast_v2` fixture (Local
  ride adult cash 1.50 on the cash medium of type 0, adult app 1.25 on the app
  medium of type 4). A twin organization carries the same product IDs at a
  different price, so a missing scope predicate shows up as a foreign amount in
  what the model read.
  """
  use GtfsPlanner.DataCase, async: false

  import GtfsPlanner.AccountsFixtures, only: [editor_fixture: 1]
  import GtfsPlanner.Agents.PackTurn
  import GtfsPlanner.FaresFixtures, only: [import!: 3, managed!: 3]
  import GtfsPlanner.OrganizationsFixtures, only: [organization_fixture: 0]
  import GtfsPlanner.VersionsFixtures, only: [gtfs_version_fixture: 1]

  alias GtfsPlanner.Agents
  alias GtfsPlanner.Agents.Dispatch
  alias GtfsPlanner.Agents.Packs.FarePrices
  alias GtfsPlanner.Agents.Scope
  alias GtfsPlanner.Gtfs.FareProduct
  alias GtfsPlanner.Repo

  setup {Req.Test, :verify_on_exit!}

  setup do
    setup_conversations()

    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    managed!(organization, version, editor_fixture(organization))

    twin_organization = organization_fixture()
    twin_version = gtfs_version_fixture(twin_organization.id)
    managed!(twin_organization, twin_version, editor_fixture(twin_organization))

    Repo.update_all(from(p in FareProduct, where: p.gtfs_version_id == ^twin_version.id),
      set: [amount: Decimal.new("9.99")]
    )

    unmanaged_version = gtfs_version_fixture(organization.id)
    import!(organization, unmanaged_version, "north_coast_v1")

    %{
      organization: organization,
      version: version,
      unmanaged_version: unmanaged_version,
      scope: version_scope(organization, version, "fare_prices")
    }
  end

  defp list(scope, arguments \\ %{}),
    do: Dispatch.call(FarePrices, scope, "list_price_cells", Jason.encode!(arguments))

  test "the registry names the pack and its two tools", context do
    assert Agents.packs()["fare_prices"] == FarePrices
    assert FarePrices.id() == "fare_prices"
    assert FarePrices.title() == "Fare price helper"

    assert Enum.map(FarePrices.tools(), & &1.name) == [
             "list_price_cells",
             "prepare_price_changes"
           ]

    assert Enum.all?(FarePrices.tools(), &(&1.parameters["additionalProperties"] == false))
    assert FarePrices.skill() =~ "list_price_cells"
    assert {:ok, _pid, %{entries: []}} = Agents.open(context.scope)
  end

  describe "list_price_cells through a composed turn" do
    test "returns the Local ride cells with structure, exact amounts and the evidence", context do
      expect_reply(
        tool_calls_reply([{"call_1", "list_price_cells", ~s({"search":"Local ride"})}])
      )

      expect_reply(text_reply("Local ride has eight prices."))

      {_pid, entry} = run_turn(context.scope, "Which Local ride prices are there?")

      assert entry.status == :done
      assert entry.activity == ["Listed fare prices"]

      assert %{"cells" => cells, "total" => 8, "currency" => "USD", "completeness" => "complete"} =
               tool_result()

      assert length(cells) == 8

      assert %{
               "fare" => "Local ride",
               "kind" => "single",
               "rider" => "Adult",
               "medium" => "Cash on board",
               "medium_type" => 0,
               "amount" => "1.50",
               "currency" => "USD"
             } = Enum.find(cells, &(&1["fare_product_id"] == "local_ride_adult_cash"))

      assert %{"medium_type" => 4, "amount" => "1.25"} =
               Enum.find(cells, &(&1["fare_product_id"] == "local_ride_adult_app"))

      assert [evidence] = entry.evidence
      assert evidence.kind == "price_cells"
      assert evidence.total == 8
      assert evidence.total_label == "price cells"
      assert evidence.completeness == :complete
      assert evidence.digest =~ ~r/\A[0-9a-f]{64}\z/
      assert evidence.scope.identity == "version:#{context.version.id}"
    end

    test "a product named for cash but sold on the app medium is reported as the app", context do
      now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

      {1, nil} =
        Repo.insert_all(FareProduct, [
          %{
            id: Ecto.UUID.generate(),
            organization_id: context.organization.id,
            gtfs_version_id: context.version.id,
            fare_product_id: "cash_single_app",
            fare_product_name: "Cash single ride",
            rider_category_id: "adult",
            fare_media_id: "app",
            amount: Decimal.new("3.00"),
            currency: "USD",
            inserted_at: now,
            updated_at: now
          }
        ])

      assert {:ok, %{"cells" => [cell]}, _evidence} =
               list(context.scope, %{"search" => "Cash single"})

      assert %{"medium_type" => 4, "fare_media_id" => "app", "amount" => "3.00"} = cell
    end
  end

  describe "refusals and bounds" do
    test "an unmanaged version returns the literal refusal and no cells", context do
      scope = version_scope(context.organization, context.unmanaged_version, "fare_prices")

      assert {:tool_error,
              "This version's fares are not edited here yet. Set them up or convert them on the Prices tab first."} =
               list(scope)
    end

    test "an identity or an arithmetic argument is refused before the pack runs", context do
      for extra <- ["organization_id", "gtfs_version_id", "percent", "round_to"] do
        assert {:tool_error, "Unexpected argument: " <> ^extra} =
                 Dispatch.call(
                   FarePrices,
                   context.scope,
                   "list_price_cells",
                   ~s({"#{extra}":"x"})
                 )
      end
    end

    test "more than 50 cells return 50, the exact total and an incomplete marker, never the twin's",
         context do
      now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

      rows =
        for number <- 1..30 do
          %{
            id: Ecto.UUID.generate(),
            organization_id: context.organization.id,
            gtfs_version_id: context.version.id,
            fare_product_id: "extra_#{number}",
            fare_product_name: "Extra #{number}",
            rider_category_id: "adult",
            fare_media_id: "cash",
            amount: Decimal.new("9.00"),
            currency: "USD",
            inserted_at: now,
            updated_at: now
          }
        end

      {30, nil} = Repo.insert_all(FareProduct, rows)

      stored =
        Repo.aggregate(
          from(p in FareProduct, where: p.gtfs_version_id == ^context.version.id),
          :count
        )

      assert {:ok, result, evidence} = list(context.scope)

      assert length(result["cells"]) == 50
      assert result["total"] == stored
      assert result["completeness"] == "incomplete"
      assert result["reason"] == "Showing 50 of #{stored}. Search for the fare you mean."
      assert evidence.total == stored
      assert evidence.completeness == :incomplete
      refute Enum.any?(result["cells"], &(&1["amount"] == "9.99"))
    end

    test "a scope that is not bound to this version reads nothing", context do
      for identity <- [nil, {:version, Ecto.UUID.generate()}] do
        scope = %{context.scope | resource_context: Scope.context(identity)}

        assert FarePrices.call("list_price_cells", %{}, scope) ==
                 {:error, "This version is no longer available."}
      end
    end
  end
end
