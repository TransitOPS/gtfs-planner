defmodule GtfsPlanner.Gtfs.PathwayEvolutions.Schedule do
  @moduledoc """
  Pure service-day evaluation for scheduled pathway closures.

  Every function here turns stored closure windows and already-loaded service-day
  origins into absolute intervals. There is no repository, timezone or graph
  access: `PathwayEvolutions` loads the origins from PostgreSQL and supplies them
  as a `%{Date.t() => DateTime.t()}` map, so this module never decides a zone and
  never re-queries a calendar. Active service dates arrive as
  `%{String.t() => [Date.t()]}` from `Calendars.ServiceDates.active_dates_between/4`.

  ## Contracts

    * A service-day time is GTFS seconds from the service-date origin, where
      `origin(d)` is local noon on `d` in the agency zone minus 12 elapsed hours.
      The origins are supplied, so a value above `24:00:00` stays above it: a
      Monday `25:00:00-26:00:00` window is a Tuesday 01:00 instant, and the same
      Monday's `49:00:00-50:00:00` window is a Wednesday 01:00 instant.
    * Windows are half-open. An instance covers
      `[origin(service_date) + start_time, origin(service_date) + end_time)`, so
      it is closed at its start and open at its end, and adjacent windows leave no
      open gap. A closure never wraps around: a window continues past midnight by
      using a value above `24:00:00`.
    * `Date` and `DateTime` values are ordered with `Date.compare/2` and
      `DateTime.compare/2`, never with `<`, `>` or term sorting. Struct term order
      compares fields by name, so `:day` would sort before `:month` and `:year`.

  ## Work

  `instance_count/2` counts the instances a load would produce from integer
  arithmetic over the active dates, so a caller can enforce its cap before
  allocating anything. It is an upper bound when the supplied dates include a
  date with no loaded origin, because `instances/3` skips those. `segments/3`
  sorts the instances and the clipped boundaries once, then sweeps the boundaries
  in order, so its cost stays proportional to the instances plus the boundaries
  rather than instances times boundaries.

  ## Ownership

  `PathwayEvolutions` owns loading, the origin query, the instance cap and the
  range limits; it supplies origins and active dates to this module and consumes
  the results. Presentation consumes the same instants, so a moment preview, a
  timeline and a range report cannot disagree about a service day.
  """

  alias GtfsPlanner.Gtfs.PathwayEvolution

  # A service-day origin sits near civil midnight, so a closure window is bounded
  # by 23 elapsed hours per service date when estimating which service dates can
  # contribute an instance. The estimate only sizes the candidate envelope; the
  # loader still widens the edges until their loaded origins bound the requested
  # interval, because an unusual historical offset transition can be longer.
  @envelope_seconds_per_date 82_800

  @type instance :: %{
          evolution_id: Ecto.UUID.t(),
          pathway_id: String.t(),
          service_id: String.t(),
          service_date: Date.t(),
          start_time: non_neg_integer(),
          end_time: non_neg_integer(),
          starts_at: DateTime.t(),
          ends_at: DateTime.t()
        }

  @type segment :: %{
          starts_at: DateTime.t(),
          ends_at: DateTime.t(),
          closed_pathway_ids: MapSet.t(String.t()),
          instances: [instance()]
        }

  @type origins :: %{Date.t() => DateTime.t()}
  @type active_dates :: %{String.t() => [Date.t()]}

  @doc """
  Returns the candidate service dates a moment preview at `service_date`/`time` needs.

  The window reaches back far enough for a closure that started on an earlier
  service date and continues forward far enough for a window that runs past the
  next origin, so a spill-over instance is never missed. The result is a lazy
  `Date.Range`; a `Date.add/2` beyond the representable date range raises, which
  the caller reports as an oversized request rather than a silent omission.
  """
  @spec preview_dates([PathwayEvolution.t()], Date.t(), non_neg_integer()) :: Date.Range.t()
  def preview_dates(closures, %Date{} = service_date, service_time)
      when is_integer(service_time) and service_time >= 0 do
    first = Date.add(service_date, -envelope_dates(max_end_time(closures)))
    last = Date.add(service_date, envelope_dates(service_time))

    Date.range(first, last)
  end

  @doc """
  Returns the candidate service dates a `first..last` range check needs.

  The range is the preview envelope widened by the closure window on both sides
  and by one extra service date at the end, so the last date's `25:00:00` window
  and the next origin both stay inside it.
  """
  @spec range_dates([PathwayEvolution.t()], Date.t(), Date.t()) :: Date.Range.t()
  def range_dates(closures, %Date{} = first, %Date{} = last) do
    dates = envelope_dates(max_end_time(closures))

    Date.range(Date.add(first, -dates), Date.add(last, dates + 1))
  end

  @doc """
  Counts the instances these closures produce over `active_dates` without building them.

  Each closure contributes one instance per active service date of its own
  service, so the count is integer arithmetic over the supplied date lists. It is
  the number a caller checks against its cap, and it never exceeds the count
  `instances/3` would produce for the same inputs.
  """
  @spec instance_count([PathwayEvolution.t()], active_dates()) :: non_neg_integer()
  def instance_count(closures, active_dates) do
    Enum.reduce(closures, 0, fn closure, total ->
      total + active_date_count(active_dates, closure.service_id)
    end)
  end

  @doc """
  Expands closures into the absolute instances their active service dates produce.

  An instance is `[origin(service_date) + start_time, origin(service_date) +
  end_time)`, and an active service date with no loaded origin contributes no
  instance, so a load that is missing an edge origin cannot invent an instant.
  Instances are ordered by absolute start, then end, then closure identity.
  """
  @spec instances([PathwayEvolution.t()], active_dates(), origins()) :: [instance()]
  def instances(closures, active_dates, origins) do
    closures
    |> Enum.flat_map(&instances_for(&1, active_dates, origins))
    |> Enum.sort_by(&instance_order/1)
  end

  @doc """
  Returns the instances covering `instant`, closed at a start and open at an end.

  Input order is preserved, so the result follows the order `instances/3` built.
  """
  @spec closed_at([instance()], DateTime.t()) :: [instance()]
  def closed_at(instances, %DateTime{} = instant) do
    Enum.filter(instances, fn instance ->
      DateTime.compare(instance.starts_at, instant) != :gt and
        DateTime.compare(instance.ends_at, instant) == :gt
    end)
  end

  @doc """
  Returns the absolute span a `first..last` range check covers.

  The span starts at the first service-date origin and ends at the later of the
  origin after `last` and the latest instance ending on `last`, so a `00:00:00`
  window on a daylight-saving service date and a `25:00:00` window on the last
  service date both fall inside it. Both origins must be loaded.
  """
  @spec horizon(origins(), [instance()], Date.t(), Date.t()) :: {DateTime.t(), DateTime.t()}
  def horizon(origins, instances, %Date{} = first, %Date{} = last) do
    start_at = origin!(origins, first)
    next_origin = origin!(origins, Date.add(last, 1))

    {start_at, later(latest_instance_end(instances, last), next_origin)}
  end

  @doc """
  Splits `[starts_at, ends_at)` into the maximal periods of one closed set.

  The span is cut at every instance start and end inside it. Ending instances are
  removed before starting ones are applied, so an instance is closed at its start
  and open at its end and adjacent windows never leave a visible gap. Every
  segment keeps the exact active instances, so a cause change is never erased:
  adjacent segments merge only when both the closed pathway set and the active
  closure identities match. An empty or reversed span has no segments.
  """
  @spec segments([instance()], DateTime.t(), DateTime.t()) :: [segment()]
  def segments(instances, %DateTime{} = starts_at, %DateTime{} = ends_at) do
    if DateTime.compare(starts_at, ends_at) == :lt do
      instances
      |> boundaries(starts_at, ends_at)
      |> sweep(instances, starts_at)
      |> merge_adjacent()
    else
      []
    end
  end

  @doc """
  Returns the service date and elapsed seconds that name `instant` exactly.

  The preferred service date is kept when the instant is not before its origin,
  so a `25:00:00` window stays `25:00:00` instead of being reparsed as a clock
  label. A target before its origin - hours that still belong to the previous
  service date, such as 22:00 EST on the evening before a spring-forward service
  date - walks back to the latest loaded origin at or before the instant and
  keeps the exact elapsed seconds. The caller must supply an origin at or before
  every target it asks about.
  """
  @spec preview_target(DateTime.t(), Date.t(), origins()) :: %{
          date: Date.t(),
          time: non_neg_integer()
        }
  def preview_target(%DateTime{} = instant, %Date{} = preferred_date, origins) do
    date = target_date(instant, preferred_date, origins)

    %{date: date, time: DateTime.diff(instant, origin!(origins, date), :second)}
  end

  # -- candidate dates --------------------------------------------------------

  defp max_end_time(closures) do
    Enum.reduce(closures, 0, fn closure, max_end -> max(closure.end_time, max_end) end)
  end

  defp envelope_dates(seconds) when seconds <= 0, do: 0

  defp envelope_dates(seconds),
    do: div(seconds + @envelope_seconds_per_date - 1, @envelope_seconds_per_date)

  defp active_date_count(active_dates, service_id) do
    case active_dates do
      %{^service_id => dates} -> length(dates)
      _ -> 0
    end
  end

  # -- instances --------------------------------------------------------------

  defp instances_for(closure, active_dates, origins) do
    active_dates
    |> Map.get(closure.service_id, [])
    |> Enum.flat_map(fn service_date ->
      case origins do
        %{^service_date => origin} -> [build_instance(closure, service_date, origin)]
        _ -> []
      end
    end)
  end

  defp build_instance(closure, service_date, origin) do
    %{
      evolution_id: closure.id,
      pathway_id: closure.pathway_id,
      service_id: closure.service_id,
      service_date: service_date,
      start_time: closure.start_time,
      end_time: closure.end_time,
      starts_at: DateTime.add(origin, closure.start_time, :second),
      ends_at: DateTime.add(origin, closure.end_time, :second)
    }
  end

  defp instance_order(instance) do
    {DateTime.to_unix(instance.starts_at), DateTime.to_unix(instance.ends_at),
     instance.evolution_id}
  end

  # -- horizon ----------------------------------------------------------------

  defp latest_instance_end(instances, last) do
    Enum.reduce(instances, nil, fn instance, latest ->
      if instance.service_date == last, do: later(instance.ends_at, latest), else: latest
    end)
  end

  defp later(nil, current), do: current
  defp later(instant, nil), do: instant

  defp later(instant, current) do
    if DateTime.compare(instant, current) == :gt, do: instant, else: current
  end

  defp origin!(origins, date) do
    case origins do
      %{^date => origin} -> origin
      _ -> raise ArgumentError, "no service-day origin loaded for #{Date.to_iso8601(date)}"
    end
  end

  # -- segments ---------------------------------------------------------------

  defp boundaries(instances, starts_at, ends_at) do
    inside =
      for instance <- instances,
          endpoint <- [instance.starts_at, instance.ends_at],
          DateTime.compare(starts_at, endpoint) == :lt,
          DateTime.compare(endpoint, ends_at) == :lt,
          do: endpoint

    [starts_at | inside]
    |> Kernel.++([ends_at])
    |> Enum.uniq_by(&DateTime.to_unix/1)
    |> Enum.sort_by(&DateTime.to_unix/1)
  end

  # Walking the boundaries once keeps this proportional to the instances plus the
  # boundaries. An instance spanning the whole horizon lands on no boundary, so
  # the half-open predicate seeds it as active at the start; each boundary then
  # applies its endings before its starts, so an instance is closed at the instant
  # it starts and open at the instant it ends.
  defp sweep(boundaries, instances, starts_at) do
    events = boundary_events(instances)
    active = MapSet.new(closed_at(instances, starts_at))

    boundaries
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.map_reduce(active, fn [left, right], active ->
      active = apply_boundary(active, Map.get(events, DateTime.to_unix(left), no_events()))

      {segment(left, right, active), active}
    end)
    |> elem(0)
  end

  defp boundary_events(instances) do
    Enum.reduce(instances, %{}, fn instance, events ->
      events
      |> add_boundary_event(DateTime.to_unix(instance.starts_at), :starts, instance)
      |> add_boundary_event(DateTime.to_unix(instance.ends_at), :endings, instance)
    end)
  end

  defp no_events, do: %{endings: [], starts: []}

  defp add_boundary_event(events, boundary, kind, instance) do
    entry = Map.get(events, boundary, no_events())

    Map.put(events, boundary, Map.update!(entry, kind, &[instance | &1]))
  end

  defp apply_boundary(active, %{endings: endings, starts: starts}) do
    active = Enum.reduce(endings, active, &MapSet.delete(&2, &1))

    Enum.reduce(starts, active, &MapSet.put(&2, &1))
  end

  defp segment(left, right, active) do
    instances = active |> MapSet.to_list() |> Enum.sort_by(&instance_order/1)

    %{
      starts_at: left,
      ends_at: right,
      closed_pathway_ids: MapSet.new(instances, & &1.pathway_id),
      instances: instances
    }
  end

  defp merge_adjacent(segments) do
    segments
    |> Enum.reduce([], fn
      segment, [] ->
        [segment]

      segment, [previous | rest] ->
        if same_causes?(previous, segment) do
          [%{previous | ends_at: segment.ends_at} | rest]
        else
          [segment, previous | rest]
        end
    end)
    |> Enum.reverse()
  end

  defp same_causes?(left, right) do
    left.closed_pathway_ids == right.closed_pathway_ids and
      identities(left.instances) == identities(right.instances)
  end

  defp identities(instances) do
    MapSet.new(instances, &{&1.evolution_id, &1.service_date})
  end

  # -- preview targets --------------------------------------------------------

  defp target_date(instant, preferred_date, origins) do
    case origins do
      %{^preferred_date => origin} ->
        if DateTime.compare(instant, origin) == :lt do
          preceding_origin_date(instant, origins)
        else
          preferred_date
        end

      _ ->
        preceding_origin_date(instant, origins)
    end
  end

  defp preceding_origin_date(instant, origins) do
    case latest_date_at_or_before(instant, origins, nil) do
      nil ->
        raise ArgumentError,
              "no service-day origin at or before #{DateTime.to_iso8601(instant)}"

      date ->
        date
    end
  end

  defp latest_date_at_or_before(instant, origins, latest) do
    Enum.reduce(origins, latest, fn {date, origin}, current ->
      if DateTime.compare(origin, instant) == :gt do
        current
      else
        keep_later_date(date, current)
      end
    end)
  end

  defp keep_later_date(date, nil), do: date

  defp keep_later_date(date, current) do
    if Date.compare(date, current) == :gt, do: date, else: current
  end
end
