defmodule GtfsPlanner.Gtfs.Blocking.Fleet do
  @moduledoc """
  The day's exact fleet demand, and how it compares with the vehicles a garage
  actually lists, as R7 defines them.

  A planner's fleet error has to answer one question exactly: at the busiest
  instant, how many vehicles does the plan need at this garage, and does the
  garage have that many? Approximating the answer by sampling the clock — 08:00
  and 08:15 — misses a peak of two vehicles inside a single five-minute block, and
  counting every interval that touches a 15-minute bin inflates the demand of
  blocks that never overlap. Both are wrong numbers a planner would act on, so
  demand here is the exact maximum number of half-open platform intervals
  `[start_secs, end_secs)` open at one instant, and the chart aggregates these
  results afterwards rather than replacing them.

  The spans are the blocks' platform spans (pull-out to pull-back, so garage
  travel is inside the interval a vehicle is committed to its garage), in
  service-day seconds. A negative start — a block pulling out before midnight —
  and an end above 86,400 are ordinary values, as in `Movements`; the peak is
  reported at the instant the plan needs it and neither is folded into the day.

  Capacity is counted twice per garage, because a garage's vehicles are listed
  per type and in total, and a block that names no type still occupies one of
  them. A typed block is checked against its garage·type listing, and *every*
  block at the garage — typed or not — is checked against the garage's total, so
  one Cutaway block plus one untyped block at a garage that lists a single
  Cutaway reports a shortfall of one on the garage total even though each
  individual check would pass. Each check therefore reports its own peak: the
  type row and the `:all` row of the same garage are computed separately and may
  disagree, which is the point.

  An unknown is not a capacity. A block with no garage, and a garage that lists
  no vehicles at all, are `:not_checked`: nothing is being claimed, so nothing is
  reported as short. Only a listing that is genuinely smaller than the demand
  is `:short`. `rows/2` is what the day load turns into `:fleet_shortfall`
  findings and what the Plan summary's fleet table renders.

  The module is pure: it computes from its arguments and calls no repository,
  clock, file or network (CR-1). The buckets are the `fleet_bucket()` list the
  planning context already carries, keyed by UUID.
  """

  alias GtfsPlanner.Gtfs.Blocking.Context
  alias GtfsPlanner.Gtfs.Schedules, as: Schedules

  @typedoc """
  One block's platform span and the garage and type it is resolved to by
  `Blocking.Context.resolve_block/3` (INV-9), so the counting rule is read from
  one place rather than re-derived here.
  """
  @type span :: %{
          garage_id: Ecto.UUID.t() | nil,
          vehicle_type_id: Ecto.UUID.t() | nil,
          start_secs: integer(),
          end_secs: integer()
        }

  @typedoc """
  One fleet table row.

  `needed` and `at_secs` are the row's own peak: the most vehicles the plan
  needs from this garage (and, for a typed row, of this type) at one instant. The
  `:all` row carries the garage's total listing, a typed row the type's, and
  `status` is `:short` only when a real listing is smaller than a real demand.
  """
  @type row :: %{
          garage_id: Ecto.UUID.t() | nil,
          vehicle_type_id: Ecto.UUID.t() | :all | nil,
          needed: non_neg_integer(),
          at_secs: integer() | nil,
          listed: non_neg_integer(),
          status: :enough | :short | :not_checked
        }

  @doc """
  Returns the largest number of spans open at one instant, and the instant.

  Spans are half-open, so two blocks touching at 08:05 count one vehicle there
  and two only where they truly overlap. The earliest instant reaching the
  maximum is reported. No span gives `%{count: 0, at_secs: nil}`.
  """
  @spec peak([span()]) :: %{count: non_neg_integer(), at_secs: integer() | nil}
  def peak([]), do: %{count: 0, at_secs: nil}

  def peak(spans) when is_list(spans) do
    # Schedules.Summary.peak_vehicles/1 takes non-negative starts, while a block
    # pulling out before midnight has a negative one. Shifting every span so the
    # earliest start is zero changes no instant's ordering and no interval's
    # length, and the reported instant is shifted back afterwards.
    offset = -min(Enum.map(spans, & &1.start_secs), 0)

    %{count: count, at_secs: at_secs} =
      Schedules.Summary.peak_vehicles(Enum.map(spans, &shift(&1, offset)))

    %{count: count, at_secs: at_secs && at_secs - offset}
  end

  @doc """
  Returns one row per garage and type the day's blocks resolve to, plus the
  garage's `:all` row and a single "No garage" row.

  A garage contributes one typed row for each type its blocks use, then its
  `:all` row; a block with no type appears only on the `:all` row, because it
  occupies one of the garage's vehicles without consuming a typed listing.
  Blocks with no garage form one `garage_id: nil` row that is never checked, and
  a garage that lists no vehicles is `:not_checked` rather than short, because a
  missing listing is not a capacity of zero. A garage or type that no block uses
  produces no row: the table reports what the plan needs, not what is parked.
  """
  @spec rows([span()], [Context.fleet_bucket()]) :: [row()]
  def rows(spans, buckets) when is_list(spans) and is_list(buckets) do
    listed_total = totals_by_garage(buckets)
    listed_typed = totals_by_garage_type(buckets)
    spans_by_garage = Enum.group_by(spans, & &1.garage_id)

    spans_by_garage
    |> Enum.reject(fn {garage_id, _spans} -> is_nil(garage_id) end)
    |> Enum.sort_by(fn {garage_id, _spans} -> garage_id end)
    |> Enum.flat_map(fn {garage_id, garage_spans} ->
      typed_rows(garage_id, garage_spans, listed_typed) ++
        [all_row(garage_id, garage_spans, listed_total)]
    end)
    |> Kernel.++(no_garage_row(Map.get(spans_by_garage, nil, [])))
  end

  defp typed_rows(garage_id, garage_spans, listed_typed) do
    garage_spans
    |> Enum.reject(fn span -> is_nil(span.vehicle_type_id) end)
    |> Enum.group_by(& &1.vehicle_type_id)
    |> Enum.sort_by(fn {vehicle_type_id, _spans} -> vehicle_type_id end)
    |> Enum.map(fn {vehicle_type_id, type_spans} ->
      listed = Map.get(listed_typed, {garage_id, vehicle_type_id}, 0)
      check(garage_id, vehicle_type_id, type_spans, listed)
    end)
  end

  defp all_row(garage_id, garage_spans, listed_total) do
    check(garage_id, :all, garage_spans, Map.get(listed_total, garage_id, 0))
  end

  defp no_garage_row([]), do: []

  defp no_garage_row(spans) do
    %{count: needed, at_secs: at_secs} = peak(spans)

    [
      %{
        garage_id: nil,
        vehicle_type_id: :all,
        needed: needed,
        at_secs: at_secs,
        listed: 0,
        status: :not_checked
      }
    ]
  end

  defp check(garage_id, vehicle_type_id, spans, 0) do
    %{count: needed, at_secs: at_secs} = peak(spans)

    %{
      garage_id: garage_id,
      vehicle_type_id: vehicle_type_id,
      needed: needed,
      at_secs: at_secs,
      listed: 0,
      status: :not_checked
    }
  end

  defp check(garage_id, vehicle_type_id, spans, listed) do
    %{count: needed, at_secs: at_secs} = peak(spans)

    %{
      garage_id: garage_id,
      vehicle_type_id: vehicle_type_id,
      needed: needed,
      at_secs: at_secs,
      listed: listed,
      status: if(needed > listed, do: :short, else: :enough)
    }
  end

  defp totals_by_garage(buckets) do
    # A vehicle with no type still occupies the garage it is parked at, so it
    # counts towards the garage total. A vehicle with no garage is parked
    # nowhere this table can check, and the "No garage" row is not checked
    # anyway, so its bucket is left out. `fleet_summary/1` buckets by garage and
    # type, so the buckets of one garage are summed rather than overwritten.
    Enum.reduce(buckets, %{}, fn
      %{garage_id: garage_id, count: count}, acc when not is_nil(garage_id) ->
        Map.update(acc, garage_id, count, &(&1 + count))

      _bucket, acc ->
        acc
    end)
  end

  defp totals_by_garage_type(buckets) do
    Enum.reduce(buckets, %{}, fn
      %{garage_id: garage_id, vehicle_type_id: vehicle_type_id, count: count}, acc
      when not is_nil(garage_id) and not is_nil(vehicle_type_id) ->
        Map.update(acc, {garage_id, vehicle_type_id}, count, &(&1 + count))

      _bucket, acc ->
        acc
    end)
  end

  defp shift(span, offset),
    do: %{span | start_secs: span.start_secs + offset, end_secs: span.end_secs + offset}
end
