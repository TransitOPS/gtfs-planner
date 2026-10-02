defmodule GtfsPlanner.Gtfs.Fares.Money do
  @moduledoc """
  The one place a fare amount is read from a person or written for one.

  Operators type what they read on a fare machine: `1.50`, `$1.50`, `.5` or
  `Free`. `parse/1` accepts exactly those, and anything else is refused so a
  mistyped price never reaches a `fare_products` row. A blank cell means not
  sold, so it parses to `nil` and the caller deletes the row rather than
  storing a zero (R9).

  Amounts are stored with the currency's minor units, which
  `minor_units/1` reads from an ISO 4217 table, and `format/2` rounds to the
  same count before rendering. A zero amount reads as `Free`, and a currency
  with no known symbol keeps its own code so a guessed symbol never misstates
  a rider's price.
  """

  # A GTFS `currency_type` is an ISO 4217 code. The symbols an operator reads
  # are the ones the reference shows; an unmapped code keeps its own code,
  # because a guessed symbol would misstate the amount.
  @currency_symbols %{"USD" => "$", "EUR" => "€", "GBP" => "£"}

  # ISO 4217 exponents. Currencies whose smallest unit is the unit itself have
  # no minor units, and the dinar and riyal family subdivides into three.
  @minor_units %{
    "JPY" => 0,
    "KRW" => 0,
    "BHD" => 3,
    "KWD" => 3,
    "JOD" => 3,
    "OMR" => 3,
    "TND" => 3
  }

  # Dollars and cents, with or without a leading digit before the point, and no
  # sign: a negative price is a different thing, refused rather than parsed.
  @amount_format ~r/^\d+(\.\d{1,2})?$|^\.\d{1,2}$/

  @doc """
  Reads what an operator typed into a price cell.

  `{:ok, Decimal}` for a price, `{:ok, Decimal.new("0")}` for `free` in any
  case, and `{:ok, nil}` for a blank cell, which means the price is not sold.
  One leading `$` is ignored. Anything else is `{:error, :invalid}`; a
  non-string is refused too, so a missing form field is never read as a price.
  A lone `$` is refused rather than read as blank, because blank deletes a price
  and a mistyped cell must never do that.
  """
  @spec parse(String.t()) :: {:ok, Decimal.t() | nil} | {:error, :invalid}
  def parse(input) when is_binary(input) do
    case String.trim(input) do
      "" ->
        {:ok, nil}

      trimmed ->
        amount = strip_currency_prefix(trimmed)

        cond do
          String.downcase(amount) == "free" -> {:ok, Decimal.new("0")}
          Regex.match?(@amount_format, amount) -> {:ok, Decimal.new(amount)}
          true -> {:error, :invalid}
        end
    end
  end

  def parse(_input), do: {:error, :invalid}

  @doc """
  How many digits a currency's smallest unit has, so a stored amount and a
  displayed amount agree. Two for USD and the rest of the common currencies,
  zero for JPY and KRW, three for the three-decimal dinars and riyals. An
  unknown code is treated as two, the GTFS default.
  """
  @spec minor_units(String.t()) :: non_neg_integer()
  def minor_units(currency) when is_binary(currency), do: Map.get(@minor_units, currency, 2)

  def minor_units(_currency), do: 2

  @doc """
  Renders a stored amount for a person: `nil` stays `nil`, a zero amount reads
  as `Free`, and any other amount is rounded to the currency's minor units and
  written with its symbol, or with the currency code when no symbol is known.
  """
  @spec format(Decimal.t() | nil, String.t()) :: String.t() | nil
  def format(nil, _currency), do: nil

  def format(amount, currency) when is_binary(currency) do
    if Decimal.equal?(amount, 0) do
      "Free"
    else
      rounded = Decimal.round(amount, minor_units(currency))

      case Map.fetch(@currency_symbols, currency) do
        {:ok, symbol} -> symbol <> Decimal.to_string(rounded)
        :error -> currency <> " " <> Decimal.to_string(rounded)
      end
    end
  end

  # One leading `$` is a symbol a person types; a second one is a typo and the
  # amount that remains is still refused below.
  defp strip_currency_prefix("$" <> amount), do: amount
  defp strip_currency_prefix(amount), do: amount
end
