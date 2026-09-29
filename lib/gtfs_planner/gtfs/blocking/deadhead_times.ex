defmodule GtfsPlanner.Gtfs.Blocking.DeadheadTimes do
  @moduledoc """
  Driving times between two planning references, as R1 defines them.

  A driving time is either *entered* — a human set it on the pair, in one
  direction only — or *estimated* from the straight-line distance between the two
  points and the version's deadhead speed and circuity. The estimate is
  `round(haversine_m × circuity ÷ (speed_kmh × 1000 / 60))` minutes and is
  symmetric, so an entered A→B value never answers a B→A lookup.

  A missing coordinate at either end gives `:unknown`, never `0`. A zero-minute
  drive would make every gap feasible, so an unknown stays unknown and the caller
  decides what an unknown means.

  Garage references carry the garage's UUID, never its correctable `garage_id`;
  `encode_ref/1` rejects a non-UUID so a garage's public ID cannot reach a stored
  driving time by accident. Stop IDs are any non-empty string, colons included.

  The module is pure: it reads its arguments and calls no repository, clock, file
  or network. `estimate_minutes/3` and `estimate_km/3` measure through
  `GtfsPlanner.Gtfs.StationReport2.Helpers.haversine/4`, the same great-circle
  helper the station report uses, so one formula serves both.
  """

  alias GtfsPlanner.Gtfs.Blocking.Context
  alias GtfsPlanner.Gtfs.StationReport2.Helpers

  @type point :: {lat :: float(), lon :: float()}

  @stop_prefix "stop:"
  @garage_prefix "garage:"

  @metres_per_km 1000
  @seconds_per_minute 60

  @doc """
  Encodes a planning reference as the `"stop:<stop_id>"` or `"garage:<uuid>"` form
  stored in `deadhead_times` and in `Context.entered_minutes` keys.

  Raises `ArgumentError` for a garage that is not a UUID: a garage's public
  `garage_id` is correctable and must never identify a stored driving time.
  """
  @spec encode_ref(Context.ref()) :: String.t()
  def encode_ref({:stop, stop_id}) when is_binary(stop_id) and stop_id != "" do
    @stop_prefix <> stop_id
  end

  def encode_ref({:garage, garage_uuid}) when is_binary(garage_uuid) do
    case Ecto.UUID.cast(garage_uuid) do
      {:ok, canonical} ->
        @garage_prefix <> canonical

      :error ->
        raise ArgumentError, "a garage ref must be the garage UUID, got: #{inspect(garage_uuid)}"
    end
  end

  @doc """
  Decodes the stored form of a planning reference.

  Returns `:error` for anything that is not one of the two forms, including a
  `garage:` prefix over a value that is not a UUID, an empty `stop:` and an
  unknown prefix, so a corrupt or hand-edited row can never become a reference.
  """
  @spec decode_ref(String.t()) :: {:ok, Context.ref()} | :error
  def decode_ref(@stop_prefix <> stop_id) when stop_id != "" do
    {:ok, {:stop, stop_id}}
  end

  def decode_ref(@garage_prefix <> garage_uuid) do
    case Ecto.UUID.cast(garage_uuid) do
      {:ok, canonical} -> {:ok, {:garage, canonical}}
      :error -> :error
    end
  end

  def decode_ref(_ref), do: :error

  @doc """
  Estimates the driving time in whole minutes between two points.

  Returns `:unknown` when either point is `nil`.
  """
  @spec estimate_minutes(point() | nil, point() | nil, Context.t()) ::
          non_neg_integer() | :unknown
  def estimate_minutes(nil, _to_point, _context), do: :unknown
  def estimate_minutes(_from_point, nil, _context), do: :unknown

  def estimate_minutes({from_lat, from_lon}, {to_lat, to_lon}, context) do
    metres = Helpers.haversine(from_lat, from_lon, to_lat, to_lon)

    round(metres * context.deadhead_circuity / metres_per_minute(context))
  end

  @doc """
  Estimates the driven distance in kilometres between two points as the straight
  line scaled by the circuity factor.

  Returns `nil` when either point is `nil`, so an unknown leg contributes nothing
  to a total rather than a zero that reads as a measured zero.
  """
  @spec estimate_km(point() | nil, point() | nil, Context.t()) :: float() | nil
  def estimate_km(nil, _to_point, _context), do: nil
  def estimate_km(_from_point, nil, _context), do: nil

  def estimate_km({from_lat, from_lon}, {to_lat, to_lon}, context) do
    Helpers.haversine(from_lat, from_lon, to_lat, to_lon) * context.deadhead_circuity /
      @metres_per_km
  end

  @doc """
  Looks the driving time up for one ordered pair, entered value first.

  An entered value for exactly `from_ref` → `to_ref` wins, including `0`. With no
  entered value the estimate answers, and with no coordinates either end the
  result is `%{minutes: nil, source: :unknown}` — never `0`.
  """
  @spec lookup(Context.ref(), point() | nil, Context.ref(), point() | nil, Context.t()) ::
          %{minutes: non_neg_integer(), source: :entered | :estimated}
          | %{minutes: nil, source: :unknown}
  def lookup(from_ref, from_point, to_ref, to_point, context) do
    case Map.fetch(context.entered_minutes, {from_ref, to_ref}) do
      {:ok, minutes} -> %{minutes: minutes, source: :entered}
      :error -> estimated(from_point, to_point, context)
    end
  end

  defp estimated(from_point, to_point, context) do
    case estimate_minutes(from_point, to_point, context) do
      :unknown -> %{minutes: nil, source: :unknown}
      minutes -> %{minutes: minutes, source: :estimated}
    end
  end

  defp metres_per_minute(context) do
    context.deadhead_speed_kmh * @metres_per_km / @seconds_per_minute
  end
end
