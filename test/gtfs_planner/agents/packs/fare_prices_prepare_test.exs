defmodule GtfsPlanner.Agents.Packs.FarePricesPrepareTest do
  @moduledoc """
  Merge evidence (EV-14) for `prepare_price_changes` through the dispatch fence
  and a composed turn: the prepared command carries exactly the rows
  `Fares.preview_price_cells/4` computed, the summary states them with the
  currency's symbol, refusals are readable, and nothing is written.

  Expected strings are hand-worked from the `north_coast_v2` fixture (Local ride
  adult cash 1.50, reduced cash 0.75, youth cash 1.00). Every case re-reads the
  stored prices to show the tool wrote nothing.
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

    %{
      organization: organization,
      version: version,
      twin_organization: twin_organization,
      twin_version: twin_version,
      scope: version_scope(organization, version, "fare_prices"),
      before: prices()
    }
  end

  defp prices do
    Repo.all(
      from(p in FareProduct,
        order_by: [p.gtfs_version_id, p.fare_product_id, p.rider_category_id, p.fare_media_id],
        select:
          {p.gtfs_version_id, p.fare_product_id, p.rider_category_id, p.fare_media_id, p.amount,
           p.updated_at}
      )
    )
  end

  defp change(product, rider, medium, amount),
    do: %{
      "fare_product_id" => product,
      "rider_category_id" => rider,
      "fare_media_id" => medium,
      "amount" => amount
    }

  @adult %{
    "fare_product_id" => "local_ride_adult_cash",
    "rider_category_id" => "adult",
    "fare_media_id" => "cash",
    "amount" => "1.75"
  }
  @reduced %{
    "fare_product_id" => "local_ride_reduced_cash",
    "rider_category_id" => "reduced",
    "fare_media_id" => "cash",
    "amount" => "0.85"
  }
  @youth %{
    "fare_product_id" => "local_ride_youth_cash",
    "rider_category_id" => "youth",
    "fare_media_id" => "cash",
    "amount" => "1.00"
  }

  defp prepare(scope, changes, currency \\ "USD"),
    do:
      Dispatch.call(
        FarePrices,
        scope,
        "prepare_price_changes",
        Jason.encode!(%{"currency" => currency, "changes" => changes})
      )

  test "two changes and one unchanged cell prepare the exact rows and the summary", context do
    assert {:prepared, prepared, result, evidence} =
             prepare(context.scope, [@adult, @reduced, @youth])

    assert prepared.command ==
             {:price_cells,
              %{
                currency: "USD",
                rows: [
                  %{
                    fare_product_id: "local_ride_adult_cash",
                    rider_category_id: "adult",
                    fare_media_id: "cash",
                    now: "1.50",
                    new: "1.75"
                  },
                  %{
                    fare_product_id: "local_ride_reduced_cash",
                    rider_category_id: "reduced",
                    fare_media_id: "cash",
                    now: "0.75",
                    new: "0.85"
                  }
                ],
                unchanged: [
                  %{
                    fare_product_id: "local_ride_youth_cash",
                    rider_category_id: "youth",
                    fare_media_id: "cash",
                    amount: "1.00"
                  }
                ]
              }}

    assert prepared.summary.title == "Change 2 prices"
    assert prepared.summary.detail == "Review the exact amounts in the Prices tab, then save."

    assert prepared.summary.lines == [
             "Local ride · Adult · Cash on board: $1.50 → $1.75",
             "Local ride · Reduced fare · Cash on board: $0.75 → $0.85",
             "Already at that price: Local ride · Youth (6-18) · Cash on board"
           ]

    assert %{"prepared" => true, "currency" => "USD", "rows" => [_, _], "unchanged" => [_]} =
             result

    assert evidence.kind == "price_changes"
    assert evidence.total == 2
    assert evidence.digest =~ ~r/\A[0-9a-f]{64}\z/

    assert prices() == context.before
  end

  describe "the schema refuses what the pack must never read" do
    test "a percent, an unknown key, a missing amount and an empty list", context do
      arguments = fn extra ->
        Map.merge(%{"currency" => "USD", "changes" => [@adult]}, extra)
      end

      assert {:tool_error, "Unexpected argument: percent"} =
               call_raw(context, arguments.(%{"percent" => "10"}))

      assert {:tool_error, "Unexpected argument: " <> _} =
               call_raw(
                 context,
                 arguments.(%{"changes" => [Map.put(@adult, "round_to", "0.05")]})
               )

      assert {:tool_error, "Missing required argument: " <> _} =
               call_raw(context, arguments.(%{"changes" => [Map.delete(@adult, "amount")]}))

      assert {:tool_error, _message} = call_raw(context, arguments.(%{"changes" => []}))

      assert {:tool_error, "Unexpected argument: organization_id"} =
               call_raw(context, arguments.(%{"organization_id" => "x"}))

      assert prices() == context.before
    end

    defp call_raw(context, arguments),
      do:
        Dispatch.call(
          FarePrices,
          context.scope,
          "prepare_price_changes",
          Jason.encode!(arguments)
        )
  end

  describe "refusals return a readable message and prepare nothing" do
    test "blank, negative and over-precise amounts", context do
      for amount <- ["", "-1", "1.505", "abc"] do
        assert {:tool_error, message} =
                 prepare(context.scope, [change("local_ride_adult_cash", "adult", "cash", amount)])

        assert message =~ "exact price like 1.75 or Free"
        assert message =~ "at most 2 decimal places for USD"
      end

      assert prices() == context.before
    end

    test "150.50 in a zero-decimal currency is refused, never stored as 151", context do
      Repo.update_all(from(p in FareProduct, where: p.gtfs_version_id == ^context.version.id),
        set: [currency: "JPY"]
      )

      before = prices()

      assert {:tool_error, message} =
               prepare(
                 context.scope,
                 [change("local_ride_adult_cash", "adult", "cash", "150.50")],
                 "JPY"
               )

      assert message =~ "at most 0 decimal places for JPY"

      assert {:prepared, _prepared, _result, _evidence} =
               prepare(
                 context.scope,
                 [change("local_ride_adult_cash", "adult", "cash", "150")],
                 "JPY"
               )

      assert prices() == before
    end

    test "a missing cell, a foreign product and a currency that is not the product's", context do
      assert {:tool_error,
              "There is no stored price for local_ride_adult_cash, rider youth, medium cash. Use list_price_cells to find the exact cells."} =
               prepare(context.scope, [change("local_ride_adult_cash", "youth", "cash", "1.00")])

      # A product only the twin organization's version holds.
      Repo.insert!(%FareProduct{
        organization_id: context.twin_organization.id,
        gtfs_version_id: context.twin_version.id,
        fare_product_id: "twin_only",
        rider_category_id: "adult",
        fare_media_id: "cash",
        amount: Decimal.new("1.00"),
        currency: "USD"
      })

      assert {:tool_error,
              "A fare product you named is not in this version. Use list_price_cells."} =
               prepare(context.scope, [change("twin_only", "adult", "cash", "1.00")])

      assert {:tool_error, "That currency is not the currency of those prices." <> _} =
               prepare(context.scope, [@adult], "CAD")

      assert {:tool_error, "The same price is listed twice." <> _} =
               prepare(context.scope, [@adult, @adult])
    end

    test "every cell already at its amount", context do
      assert {:tool_error, "Every price already equals the amount you gave."} =
               prepare(context.scope, [@youth])
    end

    test "an unmanaged version", context do
      unmanaged_version = gtfs_version_fixture(context.organization.id)
      import!(context.organization, unmanaged_version, "north_coast_v1")
      scope = version_scope(context.organization, unmanaged_version, "fare_prices")

      assert {:tool_error,
              "This version's fares are not edited here yet. Set them up or convert them on the Prices tab first."} =
               prepare(scope, [@adult])

      assert prices() == context.before
    end
  end

  test "a composed turn hands the command to Agents.prepared/3 and writes no price", context do
    arguments = Jason.encode!(%{"currency" => "USD", "changes" => [@adult, @reduced]})
    expect_reply(tool_calls_reply([{"call_1", "prepare_price_changes", arguments}]))
    expect_reply(text_reply("I prepared 2 price changes."))

    {pid, entry} =
      run_turn(context.scope, "Raise Local ride adult and reduced cash to 1.75 and 0.85")

    assert entry.status == :done
    assert entry.activity == ["Prepared price changes"]
    assert %{"prepared" => true, "rows" => [_, _]} = tool_result()

    assert {:ok, ^pid, %{conversation_id: conversation_id}} = Agents.open(context.scope)

    assert {:ok, %{command: {:price_cells, %{currency: "USD", rows: [_, _], unchanged: []}}}} =
             Agents.prepared(pid, conversation_id, entry.id)

    assert Agents.prepared(pid, conversation_id, entry.id + 1) == :error
    assert prices() == context.before
  end
end
