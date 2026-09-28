defmodule GtfsPlanner.Gtfs.Blocking.DayTypes do
  @moduledoc """
  Pure day-type derivation over the calendar summaries of one GTFS version.

  A day type is the set of dates sharing one exact set of active services. The
  module consumes the summary shape `GtfsPlanner.Gtfs.Calendars.list_calendars/3`
  returns and makes no repository calls, so the day load, the apply paths and the
  Schedules link share one date evaluation instead of deriving dates again.

  Day types are recomputed from those summaries on every load and never stored. A
  key names the day type it was derived from and resolves to nothing else.
  """

  @type calendar :: %{
          required(:service_id) => String.t(),
          required(:name) => String.t() | nil,
          required(:active_dates) => [Date.t()],
          required(:trip_count) => non_neg_integer(),
          optional(atom()) => term()
        }

  @type day_type :: %{
          key: String.t(),
          service_ids: [String.t()],
          label: String.t(),
          dates: [Date.t()],
          date_count: pos_integer(),
          first_date: Date.t(),
          last_date: Date.t(),
          trip_count: non_neg_integer(),
          special?: boolean()
        }

  @doc """
  Derives one day type per exact set of services active on the same dates.

  Order is trip count descending, then date count descending, then key ascending.

  A service "A" active on Monday and Tuesday and a service "B" active on Monday
  alone derive two day types: Monday as `{A, B}` and Tuesday as `{A}`, both keyed by
  `key/1` and labelled from the services' names.
  """
  @spec derive([calendar()]) :: [day_type()]
  def derive(calendars) do
    names = Map.new(calendars, &{&1.service_id, &1.name})
    trip_counts = Map.new(calendars, &{&1.service_id, &1.trip_count})

    calendars
    |> service_dates()
    |> dates_by_service_set()
    |> Enum.map(fn {service_ids, dates} -> day_type(service_ids, dates, names, trip_counts) end)
    |> Enum.sort_by(&{-&1.trip_count, -&1.date_count, &1.key})
  end

  @doc """
  Returns the canonical key of a set of service IDs.

  The key is the unpadded URL-safe Base64 of the SHA-256 of the sorted service IDs
  as JSON, so it does not depend on the order the IDs arrive in.
  """
  @spec key([String.t()]) :: String.t()
  def key(service_ids) do
    digest = :crypto.hash(:sha256, Jason.encode!(Enum.sort(service_ids)))
    Base.url_encode64(digest, padding: false)
  end

  @doc """
  Returns the day types whose services include `service_id`, in list order.
  """
  @spec containing([day_type()], String.t()) :: [day_type()]
  def containing(day_types, service_id) do
    Enum.filter(day_types, &(service_id in &1.service_ids))
  end

  @doc """
  Maps every service ID to the set of the dates it is active on.
  """
  @spec service_dates([calendar()]) :: %{String.t() => MapSet.t(Date.t())}
  def service_dates(calendars) do
    Map.new(calendars, &{&1.service_id, MapSet.new(&1.active_dates)})
  end

  defp dates_by_service_set(service_dates) do
    service_dates
    |> Enum.reduce(%{}, fn {service_id, dates}, acc ->
      Enum.reduce(dates, acc, fn date, acc ->
        Map.update(acc, date, MapSet.new([service_id]), &MapSet.put(&1, service_id))
      end)
    end)
    |> Enum.group_by(fn {_date, service_ids} -> service_ids end, fn {date, _} -> date end)
  end

  defp day_type(service_ids, dates, names, trip_counts) do
    service_ids = Enum.sort(service_ids)
    dates = Enum.sort(dates, Date)

    %{
      key: key(service_ids),
      service_ids: service_ids,
      label: label(service_ids, names),
      dates: dates,
      date_count: length(dates),
      first_date: hd(dates),
      last_date: List.last(dates),
      trip_count: Enum.sum(Enum.map(service_ids, &Map.fetch!(trip_counts, &1))),
      special?: length(dates) == 1
    }
  end

  defp label(service_ids, names) do
    Enum.map_join(service_ids, " + ", &name_or_id(Map.get(names, &1), &1))
  end

  defp name_or_id(name, service_id) when is_binary(name) do
    case String.trim(name) do
      "" -> service_id
      name -> name
    end
  end

  defp name_or_id(_name, service_id), do: service_id
end
