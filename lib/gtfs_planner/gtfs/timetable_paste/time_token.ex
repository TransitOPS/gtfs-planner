defmodule GtfsPlanner.Gtfs.TimetablePaste.TimeToken do
  @moduledoc """
  Classifies pasted timetable clock cells and resolves rows to GTFS seconds.

  `classify/1` reads one trimmed cell: explicit 24-hour readings (`18:05`,
  `25:10`, zero-padded hours such as `06:05`, hours of 13 and above), 12-hour
  readings with an `a`/`am`/`p`/`pm` marker, anything else clock-shaped as
  `:ambiguous`, the not-served markers as `:not_served`, and anything else as
  `{:error, :unrecognized}`. Seconds are plain GTFS clock arithmetic, so every
  classified reading round-trips through `GtfsPlanner.Gtfs.GtfsTime.format/1`.

  `resolve_row/2` walks a row left to right per rule R2: a time earlier than
  the previous one tries +12 h (ambiguous tokens only), then +24 h. A time
  that still goes backwards is `{:error, {:time_goes_backwards, index}}`,
  where `index` is the 0-based position in the input token list. The optional
  `shift` (0, 43_200 or 86_400) records the R3 twelve-hour decision and is
  added to the row's first time only; later cells roll forward from there.
  `:not_served` and `{:error, :unrecognized}` tokens pass through unchanged so
  positions stay aligned with the pasted columns.

  `twelve_hour_question?/2` answers rule R3: a row whose first time is
  ambiguous and before 04:00, in a paste whose median start is after 12:00,
  needs a decision before it is applied.
  """

  @type kind :: :h24 | :h12 | :ambiguous

  @type token ::
          {:time, non_neg_integer(), kind()} | :not_served | {:error, :unrecognized}

  @type cell ::
          %{secs: non_neg_integer(), rolled: nil | :h12 | :h24}
          | :not_served
          | {:error, :unrecognized}

  # Not-served markers per the contract: hyphen-minus, en dash (U+2013),
  # em dash (U+2014), ellipsis (U+2026), pipe, x, n/a. Compared case-insensitively.
  @not_served ["-", "–", "—", "…", "|", "x", "n/a"]

  @meridiem_suffix ~r/\A(.*?)\s*([AaPp])\.?\s*([Mm])?\.?\s*\z/
  @colon_clock ~r/\A(\d{1,2}):(\d{2})(?::(\d{2}))?\z/
  @bare_clock ~r/\A(\d{3,4})\z/

  @spec classify(String.t()) :: token()
  def classify(cell) when is_binary(cell) do
    trimmed = String.trim(cell)

    cond do
      trimmed == "" -> :not_served
      String.downcase(trimmed) in @not_served -> :not_served
      true -> parse_clock(trimmed)
    end
  end

  def classify(_cell), do: {:error, :unrecognized}

  @spec resolve_row([token()], non_neg_integer()) ::
          {:ok, [cell()]} | {:error, {:time_goes_backwards, non_neg_integer()}}
  def resolve_row(tokens, shift \\ 0)
      when is_list(tokens) and shift in [0, 43_200, 86_400] do
    result =
      Enum.reduce_while(Enum.with_index(tokens), {[], nil, false}, fn
        {token, index}, {cells, prev, seen?} ->
          case advance(token, prev, seen?, shift, index) do
            {:halt, failed_index} -> {:halt, {:backwards, failed_index}}
            {:ok, cell, next_prev, next_seen?} -> {:cont, {[cell | cells], next_prev, next_seen?}}
          end
      end)

    case result do
      {:backwards, index} -> {:error, {:time_goes_backwards, index}}
      {cells, _prev, _seen?} -> {:ok, Enum.reverse(cells)}
    end
  end

  @spec twelve_hour_question?(token(), non_neg_integer() | nil) :: boolean()
  def twelve_hour_question?({:time, secs, :ambiguous}, median) when is_integer(median) do
    secs < 4 * 3_600 and median > 12 * 3_600
  end

  def twelve_hour_question?(_token, _median), do: false

  defp advance(:not_served, prev, seen?, _shift, _index),
    do: {:ok, :not_served, prev, seen?}

  defp advance({:error, :unrecognized} = error, prev, seen?, _shift, _index),
    do: {:ok, error, prev, seen?}

  defp advance({:time, base, _kind}, _prev, false, shift, _index) do
    secs = base + shift
    {:ok, %{secs: secs, rolled: nil}, secs, true}
  end

  defp advance({:time, base, kind}, prev, true, _shift, index) do
    cond do
      base >= prev ->
        {:ok, %{secs: base, rolled: nil}, base, true}

      kind == :ambiguous and base + 43_200 >= prev ->
        {:ok, %{secs: base + 43_200, rolled: :h12}, base + 43_200, true}

      base + 86_400 >= prev ->
        {:ok, %{secs: base + 86_400, rolled: :h24}, base + 86_400, true}

      true ->
        {:halt, index}
    end
  end

  defp parse_clock(text) do
    case Regex.run(@meridiem_suffix, text) do
      [_, body, letter | _] when body != "" ->
        meridiem = if String.downcase(letter) == "p", do: :pm, else: :am
        parse_body(body, meridiem)

      _ ->
        parse_body(text, nil)
    end
  end

  defp parse_body(body, meridiem) do
    case split_clock(body) do
      {:ok, hour_text, hour, minutes, seconds} ->
        to_token(hour_text, hour, minutes, seconds, meridiem)

      :error ->
        {:error, :unrecognized}
    end
  end

  defp split_clock(body) do
    case Regex.run(@colon_clock, body) do
      [_, hour_text, minute_text] ->
        combine(hour_text, minute_text, "0")

      [_, hour_text, minute_text, ""] ->
        combine(hour_text, minute_text, "0")

      [_, hour_text, minute_text, nil] ->
        combine(hour_text, minute_text, "0")

      [_, hour_text, minute_text, second_text] ->
        combine(hour_text, minute_text, second_text)

      nil ->
        case Regex.run(@bare_clock, body) do
          [_, digits] ->
            {hour_text, minute_text} = String.split_at(digits, byte_size(digits) - 2)
            combine(hour_text, minute_text, "0")

          nil ->
            :error
        end
    end
  end

  defp combine(hour_text, minute_text, second_text) do
    with {hour, ""} <- Integer.parse(hour_text),
         {minutes, ""} <- Integer.parse(minute_text),
         {seconds, ""} <- Integer.parse(second_text),
         true <- minutes < 60 and seconds < 60 do
      {:ok, hour_text, hour, minutes, seconds}
    else
      _ -> :error
    end
  end

  defp to_token(hour_text, hour, minutes, seconds, nil) do
    kind = if leading_zero?(hour_text) or hour == 0 or hour >= 13, do: :h24, else: :ambiguous

    {:time, hour * 3_600 + minutes * 60 + seconds, kind}
  end

  defp to_token(_hour_text, hour, minutes, seconds, meridiem) when hour in 1..12 do
    base = rem(hour, 12)
    base = if meridiem == :pm, do: base + 12, else: base
    {:time, base * 3_600 + minutes * 60 + seconds, :h12}
  end

  defp to_token(_hour_text, _hour, _minutes, _seconds, _meridiem),
    do: {:error, :unrecognized}

  defp leading_zero?(hour_text),
    do: byte_size(hour_text) > 1 and String.starts_with?(hour_text, "0")
end
