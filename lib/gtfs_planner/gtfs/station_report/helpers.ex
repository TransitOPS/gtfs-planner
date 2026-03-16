defmodule GtfsPlanner.Gtfs.StationReport.Helpers do
  @moduledoc """
  Shared pure utilities for station report check submodules.
  """

  @earth_radius_m 6_371_000.0
  @known_acronyms MapSet.new(~w[BART MBTA MUNI PATH])

  @doc """
  Builds a report item map with all required keys including `category`.
  """
  @spec item(String.t(), String.t(), atom(), atom(), term(), term()) :: map()
  def item(id, label, status, category, value, details \\ nil) do
    %{
      id: id,
      label: label,
      status: status,
      category: category,
      value: value,
      details: details
    }
  end

  @doc """
  Computes the great-circle distance in meters between two lat/lon points
  using the Haversine formula. Accepts Decimal, float, or integer inputs.
  """
  @spec haversine(term(), term(), term(), term()) :: float()
  def haversine(lat1, lon1, lat2, lon2) do
    lat1 = decimal_to_float(lat1)
    lon1 = decimal_to_float(lon1)
    lat2 = decimal_to_float(lat2)
    lon2 = decimal_to_float(lon2)

    dlat = deg_to_rad(lat2 - lat1)
    dlon = deg_to_rad(lon2 - lon1)

    a =
      :math.sin(dlat / 2) * :math.sin(dlat / 2) +
        :math.cos(deg_to_rad(lat1)) * :math.cos(deg_to_rad(lat2)) *
          :math.sin(dlon / 2) * :math.sin(dlon / 2)

    a = clamp(a, 0.0, 1.0)
    c = 2 * :math.atan2(:math.sqrt(a), :math.sqrt(1 - a))

    @earth_radius_m * c
  end

  @doc """
  Converts a string to title case, lowercasing minor words (of, the, and, etc.)
  except when they appear as the first word.
  """
  @spec title_case(String.t()) :: String.t()
  def title_case(name) when is_binary(name) do
    minor_words = MapSet.new(~w[of the and in on at to for a an])

    name
    |> String.split(~r/\s+/)
    |> Enum.with_index()
    |> Enum.map(fn {word, index} ->
      downcased = String.downcase(word)

      cond do
        acronym?(word) ->
          word

        index > 0 and MapSet.member?(minor_words, downcased) ->
          downcased

        true ->
          capitalize_word(downcased)
      end
    end)
    |> Enum.join(" ")
  end

  @doc """
  Finds outliers in a list of `{key, number}` tuples using standard deviation.
  Returns items whose value exceeds `threshold` standard deviations from the mean.
  Returns `[]` if fewer than 3 samples exist.
  """
  @spec find_outliers([{term(), number()}], float()) :: [{term(), number()}]
  def find_outliers(keyed_values, threshold \\ 2.0)
  def find_outliers(keyed_values, _threshold) when length(keyed_values) < 3, do: []

  def find_outliers(keyed_values, threshold) do
    values = Enum.map(keyed_values, fn {_key, val} -> val end)
    n = length(values)
    mean = Enum.sum(values) / n

    variance = Enum.reduce(values, 0.0, fn v, acc -> acc + (v - mean) * (v - mean) end) / n
    stddev = :math.sqrt(variance)

    if stddev == 0.0 do
      []
    else
      Enum.filter(keyed_values, fn {_key, val} ->
        abs(val - mean) > threshold * stddev
      end)
    end
  end

  @doc """
  Returns `true` if the value is non-nil and non-empty-string.
  """
  @spec present?(term()) :: boolean()
  def present?(nil), do: false
  def present?(value) when is_binary(value), do: String.trim(value) != ""
  def present?(_), do: true

  @doc """
  Converts a Decimal, float, integer, or nil to float.
  """
  @spec decimal_to_float(term()) :: float() | nil
  def decimal_to_float(nil), do: nil
  def decimal_to_float(%Decimal{} = d), do: Decimal.to_float(d)
  def decimal_to_float(f) when is_float(f), do: f
  def decimal_to_float(i) when is_integer(i), do: i / 1

  # Private helpers

  defp deg_to_rad(deg), do: deg * :math.pi() / 180.0

  defp clamp(value, min, _max) when value < min, do: min
  defp clamp(value, _min, max) when value > max, do: max
  defp clamp(value, _min, _max), do: value

  defp acronym?(word) do
    upcase_token?(word) and
      (String.length(word) <= 3 or MapSet.member?(@known_acronyms, word))
  end

  defp upcase_token?(word) do
    String.match?(word, ~r/[[:upper:]]/) and
      not String.match?(word, ~r/[[:lower:]]/)
  end

  defp capitalize_word(""), do: ""

  defp capitalize_word(<<first::utf8, rest::binary>>) do
    String.upcase(<<first::utf8>>) <> rest
  end
end
