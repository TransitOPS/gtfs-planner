defmodule GtfsPlanner.Agents.Packs.FarePrices do
  @moduledoc """
  The Fare price helper pack: bounded, read-only answers about the stored prices
  of the managed service version the conversation is bound to.

  Every tool takes its organization and version from the scope, never from an
  argument, so a tool can only read the version the person is looking at (INV-1).
  `list_price_cells` lists the stored prices with the recorded structure that says
  what each one is (the fare's kind, the rider category, the payment medium and its
  type), the exact amount as a decimal string and the exact total. Nothing is
  inferred from a name, no tool writes, and none accepts an organization, a version,
  a percentage or a rounding step.
  """

  @behaviour GtfsPlanner.Agents.Pack

  alias GtfsPlanner.Agents.Packs.FareEvidence
  alias GtfsPlanner.Agents.Scope
  alias GtfsPlanner.Gtfs.Fares

  @source_ref "gtfs_fare_prices"
  @cell_limit 50
  @unavailable "This version is no longer available."
  @unmanaged "This version's fares are not edited here yet. Set them up or convert them on the Prices tab first."

  @skill_path Path.expand("../../../../priv/agents/packs/fare_prices/SKILL.md", __DIR__)
  @external_resource @skill_path

  @skill @skill_path
         |> File.read!()
         |> String.split("\n")
         |> Enum.drop_while(&(&1 != "---"))
         |> Enum.drop(1)
         |> Enum.drop_while(&(&1 != "---"))
         |> Enum.drop(1)
         |> Enum.join("\n")
         |> String.trim()

  @impl true
  def id, do: "fare_prices"

  @impl true
  def title, do: "Fare price helper"

  @impl true
  def intro do
    "I can list this version's fare prices and prepare exact price changes for you to review. I can't save or change anything."
  end

  @impl true
  def examples,
    do: [
      "Raise the Local ride adult and reduced cash prices to 1.75 and 0.85",
      "Which Local ride prices are there?"
    ]

  @impl true
  def skill, do: @skill

  @impl true
  def tools do
    [
      %{
        name: "list_price_cells",
        description:
          "List the stored prices of this version, each with its fare, kind, rider, payment medium, medium type and exact amount. search keeps the cells whose fare, product ID, rider or medium contains the text; kind keeps one recorded kind (single, pass or transfer_fee). At most #{@cell_limit} cells are returned with the exact total.",
        activity: "Listed fare prices",
        parameters: %{
          "type" => "object",
          "properties" => %{
            "search" => %{"type" => "string", "maxLength" => 100},
            "kind" => %{"type" => "string", "maxLength" => 20}
          },
          "required" => [],
          "additionalProperties" => false
        }
      }
    ]
  end

  @impl true
  def call(name, args, %Scope{} = scope) do
    case Scope.identity(scope) do
      {:version, version_id} when version_id == scope.gtfs_version_id -> run(name, args, scope)
      _other -> {:error, @unavailable}
    end
  end

  defp run("list_price_cells", args, scope), do: list_price_cells(args, scope)

  # -- tools ------------------------------------------------------------------

  defp list_price_cells(args, %Scope{} = scope) do
    opts = [
      search: blank_to_nil(args["search"]),
      kind: blank_to_nil(args["kind"]),
      limit: @cell_limit
    ]

    case Fares.list_price_cells(scope.organization_id, scope.gtfs_version_id, opts) do
      {:ok, %{currency: currency, total: total, cells: cells}} ->
        rows = Enum.map(cells, &cell_row/1)

        reason =
          if total > length(rows),
            do: "Showing #{length(rows)} of #{total}. Search for the fare you mean."

        result =
          %{"currency" => currency, "cells" => rows, "total" => total}
          |> Map.merge(completeness_fields(reason))

        evidence =
          FareEvidence.build(scope, %{
            kind: "price_cells",
            title: "Fare prices",
            total: total,
            total_label: "price cells",
            completeness: if(reason, do: :incomplete, else: :complete),
            completeness_reason: reason,
            facts: [%{label: "Currency", value: currency}],
            source_ref: @source_ref,
            digest: FareEvidence.digest({:price_cells, 1, currency, rows, total})
          })

        {:ok, result, evidence}

      {:error, :unmanaged} ->
        {:error, @unmanaged}
    end
  end

  defp cell_row(cell) do
    %{
      "fare_product_id" => cell.fare_product_id,
      "fare" => cell.fare_name,
      "kind" => cell.kind,
      "rider_category_id" => cell.rider_category_id || "",
      "rider" => cell.rider_name,
      "fare_media_id" => cell.fare_media_id || "",
      "medium" => cell.medium_name,
      "medium_type" => cell.medium_type,
      "amount" => FareEvidence.amount_string(cell.amount, cell.currency),
      "currency" => cell.currency
    }
  end

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(_value), do: nil

  defp completeness_fields(nil), do: %{"completeness" => "complete"}

  defp completeness_fields(reason),
    do: %{"completeness" => "incomplete", "reason" => reason}
end
