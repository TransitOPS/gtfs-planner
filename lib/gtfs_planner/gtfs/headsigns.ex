defmodule GtfsPlanner.Gtfs.Headsigns do
  @moduledoc """
  Pure rules for GTFS `trip_headsign` values. Every surface that reads or
  compares headsigns calls these functions instead of comparing strings.

  Domain rules:

    1. **Follows** — a trip follows default `d` when
       `normalize(trip_headsign) == normalize(d)`. `normalize/1` trims and maps
       `nil`, `""` and whitespace-only values to `nil`; comparison is
       case-sensitive, so blank equals blank.
    2. **Effective default** — the normalized timing headsign when it is
       non-nil, else the normalized pattern headsign.
    4. **Difference** — the only labelled difference is the likely typo: the
       value differs byte-for-byte but equals the default after lowercasing and
       collapsing whitespace runs. A blank value is `:blank`; a next trip in
       the block on another route is `:interline`; anything else is `:other`.
  """

  @type kind :: :blank | :case_or_spacing | :interline | :other
  @type warning :: :leading_to | :all_caps | :route_name | :sibling_case | :long
  @type lint_context :: %{
          optional(:route_short_name) => String.t() | nil,
          optional(:route_long_name) => String.t() | nil,
          optional(:sibling_headsigns) => [String.t()]
        }

  @spec normalize(String.t() | nil) :: String.t() | nil
  def normalize(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  def normalize(value), do: value

  @spec effective_default(
          timing_headsign :: String.t() | nil,
          pattern_headsign :: String.t() | nil
        ) ::
          String.t() | nil
  def effective_default(timing_headsign, pattern_headsign) do
    normalize(timing_headsign) || normalize(pattern_headsign)
  end

  @spec follows?(String.t() | nil, String.t() | nil) :: boolean()
  def follows?(trip_headsign, default_headsign) do
    normalize(trip_headsign) == normalize(default_headsign)
  end

  @spec difference(
          value :: String.t() | nil,
          default :: String.t() | nil,
          next_block :: map() | nil
        ) ::
          %{kind: kind(), likely_typo: boolean()}
  def difference(value, default, next_block) do
    cond do
      is_nil(normalize(value)) -> %{kind: :blank, likely_typo: false}
      likely_typo?(value, default) -> %{kind: :case_or_spacing, likely_typo: true}
      interline?(next_block) -> %{kind: :interline, likely_typo: false}
      true -> %{kind: :other, likely_typo: false}
    end
  end

  @spec lint(String.t() | nil, lint_context()) :: [warning()]
  def lint(nil, _context), do: []

  def lint(value, context) when is_binary(value) do
    warnings = [
      {:leading_to, Regex.match?(~r/^(to|towards)\b/i, value)},
      {:all_caps, all_caps?(value)},
      {:route_name, route_name?(value, context)},
      {:sibling_case, sibling_case?(value, context)},
      {:long, String.length(value) > 30}
    ]

    for {warning, true} <- warnings, do: warning
  end

  defp likely_typo?(value, default) do
    default = normalize(default)
    is_binary(default) and value != default and loose(value) == loose(default)
  end

  defp loose(value) do
    value
    |> String.downcase()
    |> String.replace(~r/\s+/u, " ")
  end

  defp interline?(next_block) do
    is_map(next_block) and Map.has_key?(next_block, :route_short_name)
  end

  defp all_caps?(value) do
    value == String.upcase(value) and letters(value) >= 2
  end

  defp letters(value) do
    value
    |> String.graphemes()
    |> Enum.count(&(String.upcase(&1) != String.downcase(&1)))
  end

  defp route_name?(value, context) do
    short_name = Map.get(context, :route_short_name)
    long_name = Map.get(context, :route_long_name)

    whole_word_short_name?(value, short_name) or long_name_substring?(value, long_name)
  end

  defp whole_word_short_name?(value, short_name) do
    is_binary(short_name) and String.length(short_name) >= 2 and
      Regex.match?(~r/\b#{Regex.escape(short_name)}\b/i, value)
  end

  defp long_name_substring?(value, long_name) do
    is_binary(long_name) and long_name != "" and
      String.contains?(String.downcase(value), String.downcase(long_name))
  end

  defp sibling_case?(value, context) do
    context
    |> Map.get(:sibling_headsigns, [])
    |> Enum.any?(fn sibling ->
      is_binary(sibling) and String.downcase(sibling) == String.downcase(value)
    end)
  end
end
