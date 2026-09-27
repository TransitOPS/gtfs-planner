defmodule GtfsPlanner.Gtfs.GtfsTime do
  @moduledoc """
  Parses and formats GTFS clock values as integer seconds.

  GTFS service times may continue beyond midnight, so these values do not use
  Elixir's `Time` type.
  """

  @max_seconds 2_147_483_647

  @type seconds :: non_neg_integer()
  @type offset_seconds :: integer()

  @spec parse(term()) :: {:ok, seconds()} | {:error, :invalid_time}
  def parse(value) when is_binary(value) do
    with [hours, minutes, seconds] <- String.split(value, ":"),
         {:ok, hours} <- parse_integer(hours),
         true <- two_digits?(minutes),
         true <- two_digits?(seconds),
         {:ok, minutes} <- parse_integer(minutes),
         {:ok, seconds} <- parse_integer(seconds),
         true <- minutes < 60 and seconds < 60,
         total = hours * 3_600 + minutes * 60 + seconds,
         true <- total <= @max_seconds do
      {:ok, total}
    else
      _ -> {:error, :invalid_time}
    end
  end

  def parse(_value), do: {:error, :invalid_time}

  @spec parse_offset(term()) :: {:ok, offset_seconds()} | {:error, :invalid_time}
  def parse_offset(value) when is_binary(value) do
    {sign, unsigned_value} =
      if String.starts_with?(value, "-") do
        {-1, binary_part(value, 1, byte_size(value) - 1)}
      else
        {1, value}
      end

    with true <- unsigned_value != "",
         parts when length(parts) in [2, 3] <- String.split(unsigned_value, ":"),
         {:ok, total} <- parse_elapsed_parts(parts),
         true <- total <= @max_seconds do
      {:ok, sign * total}
    else
      _ -> {:error, :invalid_time}
    end
  end

  def parse_offset(_value), do: {:error, :invalid_time}

  @spec format(seconds()) :: String.t()
  def format(seconds) when is_integer(seconds) and seconds >= 0 and seconds <= @max_seconds do
    format_unsigned(seconds)
  end

  def format(_seconds),
    do: raise(ArgumentError, "time seconds must be within the supported range")

  @spec format_offset(offset_seconds()) :: String.t()
  def format_offset(seconds)
      when is_integer(seconds) and seconds >= -@max_seconds and seconds <= @max_seconds do
    sign = if seconds < 0, do: "-", else: ""
    total = abs(seconds)

    # Elapsed offsets are minutes:seconds until they reach an hour, so a value
    # like 90 reads as 01:30 rather than 00:01:30; whole hours and beyond keep
    # the H+:MM:SS form the parser round-trips.
    if total < 3600, do: sign <> format_minutes(total), else: sign <> format_unsigned(total)
  end

  def format_offset(_seconds),
    do: raise(ArgumentError, "time offset must be within the supported range")

  defp parse_elapsed_parts([minutes, seconds]) do
    with true <- two_digits?(minutes),
         true <- two_digits?(seconds),
         {:ok, minutes} <- parse_integer(minutes),
         {:ok, seconds} <- parse_integer(seconds),
         true <- minutes < 60 and seconds < 60 do
      {:ok, minutes * 60 + seconds}
    else
      _ -> {:error, :invalid_time}
    end
  end

  defp parse_elapsed_parts([hours, minutes, seconds]) do
    with {:ok, hours} <- parse_integer(hours),
         true <- two_digits?(minutes),
         true <- two_digits?(seconds),
         {:ok, minutes} <- parse_integer(minutes),
         {:ok, seconds} <- parse_integer(seconds),
         true <- minutes < 60 and seconds < 60 do
      {:ok, hours * 3_600 + minutes * 60 + seconds}
    else
      _ -> {:error, :invalid_time}
    end
  end

  defp parse_elapsed_parts(_parts), do: {:error, :invalid_time}

  defp parse_integer(value) do
    if Regex.match?(~r/\A[0-9]+\z/, value) do
      case Integer.parse(value) do
        {number, ""} -> {:ok, number}
        _ -> {:error, :invalid_time}
      end
    else
      {:error, :invalid_time}
    end
  end

  defp two_digits?(value), do: Regex.match?(~r/\A[0-9]{2}\z/, value)

  defp format_unsigned(seconds) do
    hours = div(seconds, 3_600)
    minutes = div(rem(seconds, 3_600), 60)
    remainder = rem(seconds, 60)

    Enum.join([pad(hours), pad(minutes), pad(remainder)], ":")
  end

  defp format_minutes(seconds) do
    Enum.join([pad(div(seconds, 60)), pad(rem(seconds, 60))], ":")
  end

  defp pad(number), do: number |> Integer.to_string() |> String.pad_leading(2, "0")
end
