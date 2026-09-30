defmodule GtfsPlanner.Gtfs.Schedules.ServiceMix do
  @moduledoc """
  Refuses a new listed/frequency mix on one pattern (R9).

  A pattern and service date may carry both listed trips and frequency service only
  when that pattern and date already did. `check/3` compares one pattern's trips
  before and after an action: a date is mixed when at least one listed and at least
  one frequency trip run on it, and only dates that are mixed after and were not
  mixed before are refused. An imported mix therefore stays editable.

  `service_dates` is `Blocking.DayTypes.service_dates/1`'s map from a service ID to
  the dates that service runs; a trip whose service is missing from the map runs on
  no dates. On a refusal `service_ids` lists, sorted, every service whose trips run
  on a newly mixed date, and `date_count` counts those dates. The module is pure: it
  reads only its arguments.

  `TripChanges.MoveCalendar`, `TripChanges.Copy`, `TripChanges.Frequency` and
  `Schedules.create_trips/3` call it before writing.
  """

  @typedoc "One trip of the pattern as the caller sees it, before or after the action."
  @type trip_kind :: %{service_id: String.t(), frequency?: boolean()}

  @typedoc "A refusal naming the services whose dates the action mixed for the first time."
  @type error :: {:mixed_service, %{service_ids: [String.t()], date_count: pos_integer()}}

  @doc """
  Checks one pattern's trips before and after an action.

  Returns `:ok` when no date becomes mixed, otherwise
  `{:error, {:mixed_service, details}}`.
  """
  @spec check([trip_kind()], [trip_kind()], %{String.t() => MapSet.t(Date.t())}) ::
          :ok | {:error, error()}
  def check(before_trips, after_trips, service_dates)
      when is_list(before_trips) and is_list(after_trips) and is_map(service_dates) do
    newly_mixed =
      after_trips
      |> mixed_dates(service_dates)
      |> MapSet.difference(mixed_dates(before_trips, service_dates))

    case MapSet.size(newly_mixed) do
      0 ->
        :ok

      date_count ->
        {:error,
         {:mixed_service,
          %{
            service_ids: mixed_service_ids(after_trips, newly_mixed, service_dates),
            date_count: date_count
          }}}
    end
  end

  # The dates that carry both kinds among the given trips.
  defp mixed_dates(trips, service_dates) do
    {listed, frequency} =
      Enum.reduce(trips, {MapSet.new(), MapSet.new()}, fn trip, {listed, frequency} ->
        dates = dates_for(trip.service_id, service_dates)

        if trip.frequency? do
          {listed, MapSet.union(frequency, dates)}
        else
          {MapSet.union(listed, dates), frequency}
        end
      end)

    MapSet.intersection(listed, frequency)
  end

  defp mixed_service_ids(trips, newly_mixed, service_dates) do
    trips
    |> Enum.filter(fn trip ->
      not MapSet.disjoint?(dates_for(trip.service_id, service_dates), newly_mixed)
    end)
    |> Enum.map(& &1.service_id)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp dates_for(service_id, service_dates) do
    Map.get(service_dates, service_id, MapSet.new())
  end
end
