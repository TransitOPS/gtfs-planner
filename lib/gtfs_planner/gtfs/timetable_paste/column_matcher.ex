defmodule GtfsPlanner.Gtfs.TimetablePaste.ColumnMatcher do
  @moduledoc """
  Matches pasted timetable headers to pattern stops and trip fields.

  `normalize/1` folds a header or stop name to a comparable form: NFD
  decomposition via `:unicode.characters_to_nfd_binary/1` with combining marks
  stripped, lowercase, `&` as `and`, whole-word `st`/`sta`/`term` expanded to
  `street`/`station`/`terminal`, and punctuation collapsed to single spaces.

  `match_header/2` tries one header against the scope stops in rule R5 order:
  stop code, exact stop ID (case-sensitive), normalized stop name, trip-field
  keywords, then a unique close name (`String.jaro_distance/2` of at least
  0.9 whose best score beats the next best by at least 0.02). A trailing
  `arr`/`arrival`/`dep`/`departure` word marks the arrival or departure side
  of the matched stop; the side travels in the fifth tuple element so step 4
  can pair adjacent arrival/departure columns per rule R4. When the stripped
  base matches nothing, the whole header is retried without a side so a stop
  genuinely named e.g. "Downtown Dep" still resolves.

  Both functions are public with `@doc false`: they are internal helpers for
  `match/4` (step 4), exposed so the per-rung unit tests can assert literal
  results. Step 4 adds `match/4`, `issues/1` and `orient/2` on top of
  `match_header/2`; the `target()`/`column()` types below are kept verbatim
  from the spec Contracts section so that step compiles against them.
  """

  # Step 4 entry points (`match/4`, `issues/1`, `orient/2`) build on these
  # types; kept verbatim from the spec Contracts section.
  @type target ::
          {:occurrence, Ecto.UUID.t(), :arrival | :departure}
          | :trip_short_name
          | :block_id
          | :trip_headsign
          | :ignore
          | nil

  @type column :: %{
          col: non_neg_integer(),
          header: String.t(),
          target: target(),
          status: :exact | :close | :confirmed | :chosen | :unmatched | :unused | :out_of_order,
          by: :stop_code | :stop_id | :stop_name | :similar_name | :keyword | nil
        }

  @type stop_match_by :: :stop_code | :stop_id | :stop_name | :similar_name
  @type confidence :: :exact | :close
  @type side :: :arrival | :departure | nil
  @type trip_field :: :trip_short_name | :block_id | :trip_headsign

  @type stop_entry :: %{
          optional(:stop_code) => String.t() | nil,
          optional(:stop_name) => String.t()
        }

  @type header_match ::
          {:stop, String.t(), stop_match_by(), confidence(), side()}
          | {:field, trip_field()}
          | :none

  @close_threshold 0.9
  @uniqueness_gap 0.02

  @abbreviations %{"st" => "street", "sta" => "station", "term" => "terminal"}

  # Normalized keyword forms ("Trip #"/"Block #" collapse to "trip"/"block").
  # "Run" is deliberately absent: it is never a trip-number keyword (R5).
  @trip_fields %{
    "trip" => :trip_short_name,
    "trip no" => :trip_short_name,
    "trip number" => :trip_short_name,
    "train" => :trip_short_name,
    "block" => :block_id,
    "block id" => :block_id,
    "headsign" => :trip_headsign,
    "destination" => :trip_headsign
  }

  @side_words %{
    "arr" => :arrival,
    "arrival" => :arrival,
    "dep" => :departure,
    "departure" => :departure
  }

  # A side word only counts after a separator, so names ending in similar
  # letters ("Barr", "Depot", "Departures") never strip.
  @side_suffix ~r/[\s,;:\-–—_\[\(]+(arr|arrival|dep|departure)[\s\.\)\]]*$/i

  @doc false
  @spec normalize(String.t()) :: String.t()
  def normalize(text) when is_binary(text) do
    text
    |> :unicode.characters_to_nfd_binary()
    |> String.replace(~r/\p{Mn}/u, "")
    |> String.downcase()
    |> String.replace("&", " and ")
    |> String.replace(~r/[^\p{L}\p{N}\s]+/u, " ")
    |> String.split()
    |> Enum.map(&Map.get(@abbreviations, &1, &1))
    |> Enum.join(" ")
  end

  @doc false
  @spec match_header(String.t(), %{optional(String.t()) => stop_entry()}) ::
          header_match()
  def match_header(header, stops) when is_binary(header) and is_map(stops) do
    trimmed = String.trim(header)
    {base, side} = split_side(trimmed)

    case match_base(base, stops) do
      {:stop, stop_id, by, confidence} -> {:stop, stop_id, by, confidence, side}
      {:field, _field} = field -> field
      :none when side != nil -> retry_whole_header(trimmed, stops)
      :none -> :none
    end
  end

  @spec retry_whole_header(String.t(), %{optional(String.t()) => stop_entry()}) ::
          header_match()
  defp retry_whole_header(trimmed, stops) do
    case match_base(trimmed, stops) do
      {:stop, stop_id, by, confidence} -> {:stop, stop_id, by, confidence, nil}
      other -> other
    end
  end

  @spec match_base(String.t(), %{optional(String.t()) => stop_entry()}) ::
          {:stop, String.t(), stop_match_by(), confidence()}
          | {:field, trip_field()}
          | :none
  defp match_base("", _stops), do: :none

  defp match_base(base, stops) do
    normalized = normalize(base)

    if normalized == "" do
      :none
    else
      ordered = stops |> Map.to_list() |> Enum.sort_by(&elem(&1, 0))

      with :none <- match_stop_code(ordered, normalized),
           :none <- match_stop_id(ordered, base),
           :none <- match_stop_name(ordered, normalized),
           :none <- match_keyword(normalized) do
        match_close_name(ordered, normalized)
      end
    end
  end

  @spec match_stop_code([{String.t(), stop_entry()}], String.t()) ::
          {:stop, String.t(), :stop_code, :exact} | :none
  defp match_stop_code(ordered, normalized) do
    Enum.find_value(ordered, :none, fn {stop_id, stop} ->
      case Map.get(stop, :stop_code) do
        nil -> nil
        code -> if normalize(code) == normalized, do: {:stop, stop_id, :stop_code, :exact}
      end
    end)
  end

  @spec match_stop_id([{String.t(), stop_entry()}], String.t()) ::
          {:stop, String.t(), :stop_id, :exact} | :none
  defp match_stop_id(ordered, base) do
    Enum.find_value(ordered, :none, fn {stop_id, _stop} ->
      if stop_id == base, do: {:stop, stop_id, :stop_id, :exact}
    end)
  end

  @spec match_stop_name([{String.t(), stop_entry()}], String.t()) ::
          {:stop, String.t(), :stop_name, :exact} | :none
  defp match_stop_name(ordered, normalized) do
    Enum.find_value(ordered, :none, fn {stop_id, stop} ->
      if normalize(Map.get(stop, :stop_name, "")) == normalized do
        {:stop, stop_id, :stop_name, :exact}
      end
    end)
  end

  @spec match_keyword(String.t()) :: {:field, trip_field()} | :none
  defp match_keyword(normalized) do
    case Map.get(@trip_fields, normalized) do
      nil -> :none
      field -> {:field, field}
    end
  end

  @spec match_close_name([{String.t(), stop_entry()}], String.t()) ::
          {:stop, String.t(), :similar_name, :close} | :none
  defp match_close_name(ordered, normalized) do
    scored =
      ordered
      |> Enum.map(fn {stop_id, stop} ->
        {stop_id, String.jaro_distance(normalized, normalize(Map.get(stop, :stop_name, "")))}
      end)
      |> Enum.sort_by(&elem(&1, 1), :desc)

    case scored do
      [{stop_id, best} | rest] when best >= @close_threshold ->
        second =
          case rest do
            [{_id, score} | _] -> score
            [] -> 0.0
          end

        if best - second >= @uniqueness_gap do
          {:stop, stop_id, :similar_name, :close}
        else
          :none
        end

      _ ->
        :none
    end
  end

  @spec split_side(String.t()) :: {String.t(), side()}
  defp split_side(trimmed) do
    case Regex.run(@side_suffix, trimmed) do
      [suffix, word] ->
        base =
          trimmed
          |> :binary.part(0, byte_size(trimmed) - byte_size(suffix))
          |> String.trim_trailing()

        {base, Map.fetch!(@side_words, String.downcase(word))}

      nil ->
        {trimmed, nil}
    end
  end
end
