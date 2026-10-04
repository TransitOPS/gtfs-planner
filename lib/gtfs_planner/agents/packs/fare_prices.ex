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
  a percentage or a rounding step. `prepare_price_changes` takes a currency and
  explicit product, rider, medium and amount strings, previews them through
  `Fares.preview_price_cells/4` and returns a prepared command with the exact
  before and after rows; the native price review decides whether and when they are
  saved.
  """

  @behaviour GtfsPlanner.Agents.Pack

  alias GtfsPlanner.Agents.Packs.FareEvidence
  alias GtfsPlanner.Agents.Scope
  alias GtfsPlanner.Gtfs.Fares
  alias GtfsPlanner.Gtfs.Fares.Money
  alias GtfsPlanner.Wording

  @source_ref "gtfs_fare_prices"
  @cell_limit 50
  @unavailable "This version is no longer available."
  @summary_row_limit 10
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
      },
      %{
        name: "prepare_price_changes",
        description:
          "Prepare exact price changes for the person to review. currency is the ISO code the prices are in. Each change names one stored price by fare_product_id, rider_category_id and fare_media_id exactly as list_price_cells returned them (an empty string means none) and gives its new amount as a decimal string such as 1.75 or Free. No percentages and no rounding: ask for exact amounts. Nothing is saved; the person reviews the exact before and after on the Prices tab and saves there.",
        activity: "Prepared price changes",
        parameters: %{
          "type" => "object",
          "properties" => %{
            "currency" => %{"type" => "string", "minLength" => 1, "maxLength" => 8},
            "changes" => %{
              "type" => "array",
              "minItems" => 1,
              "maxItems" => @cell_limit,
              "items" => %{
                "type" => "object",
                "properties" => %{
                  "fare_product_id" => %{"type" => "string", "maxLength" => 200},
                  "rider_category_id" => %{"type" => "string", "maxLength" => 200},
                  "fare_media_id" => %{"type" => "string", "maxLength" => 200},
                  "amount" => %{"type" => "string", "maxLength" => 20}
                },
                "required" => ["fare_product_id", "rider_category_id", "fare_media_id", "amount"],
                "additionalProperties" => false
              }
            }
          },
          "required" => ["currency", "changes"],
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
  defp run("prepare_price_changes", args, scope), do: prepare_price_changes(args, scope)

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

  defp prepare_price_changes(args, %Scope{} = scope) do
    with {:ok, currency, cells} <- parse_changes(args),
         {:ok, %{rows: rows, unchanged: unchanged}} <-
           preview(scope, currency, cells),
         :ok <- require_rows(rows) do
      prepared_changes(scope, currency, rows, unchanged)
    end
  end

  defp parse_changes(%{"currency" => currency, "changes" => changes})
       when is_binary(currency) and is_list(changes) do
    cells = Enum.map(changes, &change_cell/1)

    if currency != "" and Enum.all?(cells, &(&1 != :invalid)),
      do: {:ok, currency, cells},
      else:
        {:error, "Give the currency and, for each change, the product, rider, medium and amount."}
  end

  defp parse_changes(_args),
    do: {:error, "Give the currency and, for each change, the product, rider, medium and amount."}

  defp change_cell(%{
         "fare_product_id" => product,
         "rider_category_id" => rider,
         "fare_media_id" => medium,
         "amount" => amount
       })
       when is_binary(product) and is_binary(rider) and is_binary(medium) and is_binary(amount) do
    %{
      fare_product_id: product,
      rider_category_id: empty_to_nil(rider),
      fare_media_id: empty_to_nil(medium),
      amount: amount
    }
  end

  defp change_cell(_change), do: :invalid

  defp empty_to_nil(""), do: nil
  defp empty_to_nil(value), do: value

  defp preview(scope, currency, cells) do
    case Fares.preview_price_cells(scope.organization_id, scope.gtfs_version_id, currency, cells) do
      {:ok, preview} -> {:ok, preview}
      {:error, reason} -> {:error, preview_error(reason, currency)}
    end
  end

  defp preview_error(:unmanaged, _currency), do: @unmanaged
  defp preview_error(:no_prices, _currency), do: "Give at least one price to change."
  defp preview_error(:too_many, _currency), do: "Change at most #{@cell_limit} prices at a time."

  defp preview_error(:invalid_price, currency),
    do:
      "Each amount must be an exact price like 1.75 or Free, with at most #{Money.minor_units(currency)} decimal places for #{currency}. Nothing is rounded."

  defp preview_error(:duplicate_cell, _currency),
    do: "The same price is listed twice. List each product, rider and medium once."

  defp preview_error(:not_found, _currency),
    do: "A fare product you named is not in this version. Use list_price_cells."

  defp preview_error(:currency_mismatch, _currency),
    do: "That currency is not the currency of those prices. Read it with list_price_cells."

  defp preview_error({:missing_cell, {product, rider, medium}}, _currency),
    do:
      "There is no stored price for #{product}, rider #{rider || "none"}, medium #{medium || "none"}. Use list_price_cells to find the exact cells."

  defp require_rows([]), do: {:error, "Every price already equals the amount you gave."}
  defp require_rows(_rows), do: :ok

  # Nothing is written here. The command carries the exact rows the native review
  # recomputes and fences; `unchanged` carries each cell already at its amount so
  # the host can re-verify it too.
  defp prepared_changes(scope, currency, rows, unchanged) do
    command_rows = Enum.map(rows, &command_row(&1, currency))
    command_unchanged = Enum.map(unchanged, &unchanged_row(&1, currency))

    prepared = %{
      command:
        {:price_cells, %{currency: currency, rows: command_rows, unchanged: command_unchanged}},
      summary: %{
        title: "Change #{Wording.count_noun(length(rows), "price")}",
        detail: "Review the exact amounts in the Prices tab, then save.",
        lines: summary_lines(rows, unchanged, currency)
      }
    }

    result = %{
      "prepared" => true,
      "currency" => currency,
      "rows" => Enum.map(command_rows, &json_cell/1),
      "unchanged" => Enum.map(command_unchanged, &json_cell/1)
    }

    evidence =
      FareEvidence.build(scope, %{
        kind: "price_changes",
        title: "Price changes",
        total: length(rows),
        total_label: "prices to change",
        facts: [
          %{label: "Currency", value: currency},
          %{label: "Already at the amount", value: Integer.to_string(length(unchanged))}
        ],
        source_ref: @source_ref,
        digest: FareEvidence.digest({:price_changes, 1, currency, command_rows})
      })

    {:prepared, prepared, result, evidence}
  end

  defp command_row(row, currency) do
    %{
      fare_product_id: row.fare_product_id,
      rider_category_id: row.rider_category_id,
      fare_media_id: row.fare_media_id,
      now: FareEvidence.amount_string(row.now, currency),
      new: FareEvidence.amount_string(row.new, currency)
    }
  end

  defp unchanged_row(row, currency) do
    %{
      fare_product_id: row.fare_product_id,
      rider_category_id: row.rider_category_id,
      fare_media_id: row.fare_media_id,
      amount: FareEvidence.amount_string(row.amount, currency)
    }
  end

  defp json_cell(cell) do
    Map.new(cell, fn {key, value} -> {Atom.to_string(key), value || ""} end)
  end

  defp summary_lines(rows, unchanged, currency) do
    shown = Enum.take(rows, @summary_row_limit)
    more = length(rows) - length(shown)

    Enum.map(shown, fn row ->
      "#{label(row)}: #{Money.format(row.now, currency)} → #{Money.format(row.new, currency)}"
    end) ++
      if(more > 0, do: ["and #{more} more"], else: []) ++
      unchanged_line(unchanged)
  end

  defp unchanged_line([]), do: []

  defp unchanged_line(unchanged) do
    names = unchanged |> Enum.take(3) |> Enum.map_join(", ", &label/1)
    more = length(unchanged) - 3
    suffix = if more > 0, do: " and #{more} more", else: ""
    ["Already at that price: #{names}#{suffix}"]
  end

  defp label(price) do
    [
      price.fare_name,
      price.rider_name || price.rider_category_id || "any rider",
      price.medium_name || price.fare_media_id || "any payment"
    ]
    |> Enum.join(" · ")
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
