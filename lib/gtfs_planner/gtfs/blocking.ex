defmodule GtfsPlanner.Gtfs.Blocking do
  @moduledoc """
  Scoped reads and writes for the Blocks page.

  Every function is scoped to one organization and GTFS version: organization,
  version and actor come from arguments, never from submitted parameters. The
  minimum layover is stored per published version, read as a default without
  writing a row, and validated before it reaches the table.

  `load_day/3` loads one day type of a published version inside one transaction:
  it derives the day types from `Calendars.list_calendars/3`, selects the requested
  key, reads the day type's trips with their endpoints through `Blocking.Queries`
  and assembles blocks, the pool, findings, counts, the peak and the timeline axis.
  Every trip of the day type appears exactly once, in the block named by its
  `block_id` or in the pool (R2, AC-2).

  The day also carries every type 4/5 record naming one of its trips, evaluated by
  the shared `Blocking.InSeat` rule over every day type both of the record's trips
  run in, not only the selected one (R6, AC-7, INV-2).
  """

  import Ecto.Query, warn: false

  alias GtfsPlanner.Gtfs.Blocking.{Checks, DayTypes, InSeat, Queries, Summary}
  alias GtfsPlanner.Gtfs.BlockingSetting
  alias GtfsPlanner.Gtfs.Calendars
  alias GtfsPlanner.Gtfs.Trip
  alias GtfsPlanner.Repo
  alias GtfsPlanner.Versions

  @default_min_layover_minutes 5
  @seconds_per_hour 3600

  # The timeline chart and the Peak drawer bucket the day in 15-minute bins.
  @bin_secs 900

  @type block :: %{
          summary: Summary.block_summary(),
          trips: [Queries.trip_row()],
          gaps: [Checks.gap()],
          findings: [Checks.finding()]
        }

  @type in_seat_entry :: %{row: Queries.in_seat_row(), state: InSeat.state()}

  @type day :: %{
          day_types: [DayTypes.day_type()],
          day_type: DayTypes.day_type() | nil,
          settings: %{min_layover_minutes: 0..120},
          routes: %{String.t() => Queries.route_info()},
          blocks: [block()],
          pool: [Queries.trip_row()],
          unplottable: [Queries.trip_row()],
          findings: [Checks.finding()],
          # by each named trip in the day type
          in_seat: %{Ecto.UUID.t() => [in_seat_entry()]},
          counts: %{
            blocks: non_neg_integer(),
            trips: non_neg_integer(),
            unassigned: non_neg_integer(),
            problems: non_neg_integer(),
            notices: non_neg_integer()
          },
          peak: %{
            count: non_neg_integer(),
            at_secs: integer() | nil,
            excluded_unassigned: non_neg_integer(),
            excluded_frequency: non_neg_integer()
          },
          bins: [%{start_secs: integer(), count: non_neg_integer()}],
          axis: %{start_secs: integer(), end_secs: integer()} | nil,
          mixed_timezones?: boolean()
        }

  @doc """
  Returns the minimum layover for one organization's GTFS version.

  A version with no stored row returns the default and stores nothing.

  ## Examples

      iex> get_settings(organization_id, gtfs_version_id)
      %{min_layover_minutes: 5}
  """
  @spec get_settings(Ecto.UUID.t(), Ecto.UUID.t()) :: %{min_layover_minutes: 0..120}
  def get_settings(organization_id, gtfs_version_id) do
    case Repo.one(settings_query(organization_id, gtfs_version_id)) do
      %{min_layover_minutes: minutes} -> %{min_layover_minutes: minutes}
      nil -> %{min_layover_minutes: @default_min_layover_minutes}
    end
  end

  @doc """
  Returns the changeset rendered by the minimum layover form.

  `settings` is a value map from `get_settings/2` and `attrs` are the submitted
  parameters; an invalid value carries the field error.
  """
  @spec change_settings(map(), map()) :: Ecto.Changeset.t()
  def change_settings(settings, attrs) do
    %BlockingSetting{}
    |> Ecto.Changeset.change(
      min_layover_minutes: Map.get(settings, :min_layover_minutes, @default_min_layover_minutes)
    )
    |> BlockingSetting.changeset(attrs)
  end

  @doc """
  Stores the minimum layover for one organization's published GTFS version.

  Returns `{:error, :not_found}` when the version is unpublished or belongs to
  another organization, and `{:error, changeset}` when the value is not a whole
  number from 0 to 120. One row is kept per organization and version, so a
  repeated save replaces the stored value.
  """
  @spec update_settings(Ecto.UUID.t(), Ecto.UUID.t(), map()) ::
          {:ok, BlockingSetting.t()} | {:error, Ecto.Changeset.t() | :not_found}
  def update_settings(organization_id, gtfs_version_id, attrs) do
    if Versions.published_gtfs_version_for_org?(organization_id, gtfs_version_id) do
      %BlockingSetting{organization_id: organization_id, gtfs_version_id: gtfs_version_id}
      |> BlockingSetting.changeset(attrs)
      |> Repo.insert(
        on_conflict: {:replace, [:min_layover_minutes, :updated_at]},
        conflict_target: [:organization_id, :gtfs_version_id],
        returning: true
      )
    else
      {:error, :not_found}
    end
  end

  defp settings_query(organization_id, gtfs_version_id) do
    from(s in BlockingSetting,
      where: s.organization_id == ^organization_id and s.gtfs_version_id == ^gtfs_version_id,
      select: %{min_layover_minutes: s.min_layover_minutes}
    )
  end

  @doc """
  Loads one day type of a published version as blocks, the pool and the day's checks.

  A `nil` key selects the first day type in `DayTypes.derive/1` order. An unknown
  key returns `{:error, {:unknown_day_type, day_types}}` and selects none: nothing
  falls back to another day type (INV-6). A version whose calendars derive no day
  type returns an empty day with `day_type: nil`. A foreign or unpublished version
  is `{:error, :not_found}` through `Calendars.list_calendars/3`, which also takes
  the published version row `FOR SHARE` for the whole read.

  Every trip of the selected day type is returned exactly once: in the block named
  by its `block_id` or in the pool. A trip without usable endpoint times is also
  listed in `unplottable` and counted (AC-2, AC-6). The query count does not grow
  with the trip count (AC-3).
  """
  @spec load_day(Ecto.UUID.t(), Ecto.UUID.t(), String.t() | nil) ::
          {:ok, day()} | {:error, :not_found | {:unknown_day_type, [DayTypes.day_type()]}}
  def load_day(organization_id, gtfs_version_id, day_type_key) do
    case Repo.transaction(fn -> read_day(organization_id, gtfs_version_id, day_type_key) end) do
      {:ok, day} -> {:ok, day}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Returns the day types one natural trip ID runs in.

  The trip must belong to this organization and version; anything else is
  `{:error, :not_found}`. The day types come from the same derivation the day load
  uses and keep its list order, so the answer names every date the trip runs.
  """
  @spec trip_day_types(Ecto.UUID.t(), Ecto.UUID.t(), String.t()) ::
          {:ok, %{trip_id: String.t(), day_types: [DayTypes.day_type()]}} | {:error, :not_found}
  def trip_day_types(organization_id, gtfs_version_id, trip_id) do
    case Repo.transaction(fn ->
           calendars = load_calendars!(organization_id, gtfs_version_id)
           service_id = trip_service_id!(organization_id, gtfs_version_id, trip_id)

           %{
             trip_id: trip_id,
             day_types: DayTypes.containing(DayTypes.derive(calendars), service_id)
           }
         end) do
      {:ok, result} -> {:ok, result}
      {:error, reason} -> {:error, reason}
    end
  end

  defp read_day(organization_id, gtfs_version_id, day_type_key) do
    calendars = load_calendars!(organization_id, gtfs_version_id)
    day_types = DayTypes.derive(calendars)
    day_type = resolve_day_type!(day_types, day_type_key)
    trips = day_trips(organization_id, gtfs_version_id, day_type)
    settings = get_settings(organization_id, gtfs_version_id)

    day = %{
      day_types: day_types,
      day_type: day_type,
      settings: settings,
      routes: Queries.routes(organization_id, gtfs_version_id, Enum.map(trips, & &1.route_id)),
      mixed_timezones?: Queries.mixed_timezones?(organization_id, gtfs_version_id)
    }

    Map.merge(
      day,
      assemble(
        organization_id,
        gtfs_version_id,
        day_types,
        DayTypes.service_dates(calendars),
        trips,
        settings.min_layover_minutes
      )
    )
  end

  defp day_trips(_organization_id, _gtfs_version_id, nil), do: []

  defp day_trips(organization_id, gtfs_version_id, %{service_ids: service_ids}) do
    Queries.trip_rows(organization_id, gtfs_version_id, {:services, service_ids})
  end

  # An empty version has no day type to resolve, so any key loads the empty day
  # rather than an unknown-key error (Day loading step 2).
  defp resolve_day_type!([], _day_type_key), do: nil
  defp resolve_day_type!(day_types, nil), do: hd(day_types)

  defp resolve_day_type!(day_types, day_type_key) do
    Enum.find(day_types, &(&1.key == day_type_key)) ||
      Repo.rollback({:unknown_day_type, day_types})
  end

  defp load_calendars!(organization_id, gtfs_version_id) do
    case Calendars.list_calendars(organization_id, gtfs_version_id) do
      {:ok, summaries} -> summaries
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp trip_service_id!(organization_id, gtfs_version_id, trip_id) do
    query =
      from(t in Trip,
        where:
          t.organization_id == ^organization_id and t.gtfs_version_id == ^gtfs_version_id and
            t.trip_id == ^trip_id,
        select: t.service_id
      )

    Repo.one(query) || Repo.rollback(:not_found)
  end

  defp assemble(organization_id, gtfs_version_id, day_types, service_dates, trips, min_layover) do
    {pool_trips, blocked_trips} = Enum.split_with(trips, &is_nil(&1.block_id))

    in_seat =
      in_seat_context(
        organization_id,
        gtfs_version_id,
        day_types,
        service_dates,
        trips
      )

    states = Enum.map(in_seat.rows, &{&1, InSeat.state(&1, in_seat.context)})

    in_seat_findings =
      states
      |> Enum.map(fn {row, state} -> InSeat.finding(row, state, in_seat.context) end)
      |> Enum.reject(&is_nil/1)

    in_seat_by_block =
      in_seat_findings
      |> Enum.filter(&is_binary(&1.block_id))
      |> Enum.group_by(& &1.block_id)

    blocks =
      blocked_trips
      |> Enum.group_by(& &1.block_id)
      |> Enum.map(fn {block_id, block_trips} ->
        build_block(
          block_id,
          block_trips,
          min_layover,
          Map.get(in_seat_by_block, block_id, [])
        )
      end)
      |> Enum.sort_by(&Summary.natural_key(&1.summary.block_id))

    pool = order_pool(pool_trips)

    findings =
      (Enum.flat_map(blocks, & &1.findings) ++
         pool_notices(pool_trips, min_layover) ++ in_seat_findings)
      |> Enum.uniq_by(&Checks.finding_key/1)

    summaries = Enum.map(blocks, & &1.summary)
    peak = Summary.peak(summaries)

    %{
      blocks: blocks,
      pool: pool,
      unplottable: Enum.sort_by(Enum.reject(trips, & &1.plottable?), & &1.trip_id),
      findings: findings,
      in_seat: in_seat_entries(states, trips),
      counts: %{
        blocks: length(blocks),
        trips: length(trips),
        unassigned: length(pool_trips),
        problems: Enum.count(findings, &(&1.severity in [:error, :warning])),
        notices: Enum.count(findings, &(&1.severity == :notice))
      },
      peak: %{
        count: peak.count,
        at_secs: peak.at_secs,
        excluded_unassigned: length(pool_trips),
        excluded_frequency: Enum.count(trips, & &1.frequency?)
      },
      bins: Summary.bins(summaries, @bin_secs),
      axis: axis(trips)
    }
  end

  defp build_block(block_id, trips, min_layover_minutes, in_seat_findings) do
    findings =
      (Checks.block_findings(block_id, trips, min_layover_minutes) ++ in_seat_findings)
      |> Enum.uniq_by(&Checks.finding_key/1)

    %{
      summary: Summary.block_summary(block_id, trips, findings),
      trips: order_block_trips(trips),
      gaps: Checks.gaps(Checks.sequence(trips)),
      findings: findings
    }
  end

  # One entry per named trip the day type holds, under that trip's UUID, in the
  # reading order of the records (AC-7). A record whose other trip runs elsewhere
  # is listed under the trip that is here; a record naming a trip the version does
  # not hold is listed under the trip that is.
  defp in_seat_entries(states, trips) do
    uuid_by_trip_id = Map.new(trips, &{&1.trip_id, &1.id})

    states
    |> Enum.flat_map(fn {row, state} ->
      entry = %{row: row, state: state}

      [row.from_trip_id, row.to_trip_id]
      |> Enum.uniq()
      |> Enum.flat_map(&named_entry(&1, entry, uuid_by_trip_id))
    end)
    |> Enum.reduce(%{}, fn {uuid, entry}, acc -> Map.update(acc, uuid, [entry], &[entry | &1]) end)
    |> Map.new(fn {uuid, entries} -> {uuid, Enum.reverse(entries)} end)
  end

  defp named_entry(trip_id, entry, uuid_by_trip_id) do
    case Map.fetch(uuid_by_trip_id, trip_id) do
      {:ok, uuid} -> [{uuid, entry}]
      :error -> []
    end
  end

  # The in-seat context of the given trips: the type 4/5 records naming any of
  # them, the trips those records name, and the orders R6 needs. One query per kind
  # answers whatever the number of trips or records; nothing is queried per record
  # or per block (AC-3). The day types are the caller's, so a caller can restrict
  # the evaluation to the day types it is responsible for (step 12). Every record
  # whose two trips are both blocked is evaluated, whether or not the two share one
  # block ID: only the rule can decide that a cross-block pair is not next.
  defp in_seat_context(organization_id, gtfs_version_id, day_types, service_dates, trips) do
    rows =
      Queries.in_seat_rows(organization_id, gtfs_version_id, Enum.map(trips, & &1.trip_id))

    trips = named_trips(organization_id, gtfs_version_id, rows, trips)
    evaluated = both_service_day_types(day_types, rows, trips)
    block_rows = block_rows(organization_id, gtfs_version_id, evaluated, rows, trips)

    %{
      rows: rows,
      context: %{
        trips: trips,
        service_dates: service_dates,
        day_types: evaluated,
        sequences: sequences(evaluated, block_rows)
      }
    }
  end

  # The trips a record names are read once for the whole set, and only those the
  # caller did not already hand over. A trip the version does not hold is simply
  # absent, which the rule reports as `:trip_missing`.
  defp named_trips(organization_id, gtfs_version_id, rows, trips) do
    trips = Map.new(trips, &{&1.trip_id, &1})

    missing =
      rows
      |> Enum.flat_map(&[&1.from_trip_id, &1.to_trip_id])
      |> Enum.uniq()
      |> Enum.reject(&Map.has_key?(trips, &1))

    Enum.reduce(
      Queries.trip_rows(organization_id, gtfs_version_id, {:trip_ids, missing}),
      trips,
      &Map.put(&2, &1.trip_id, &1)
    )
  end

  # R6 evaluates every day type both of a record's trips run in, so the context is
  # every day type containing both services of a record whose two trips are
  # blocked. The two trips need not share one block ID: whether the second follows
  # the first in one block is exactly what the rule decides, and withholding the
  # day type here would suppress the check and report a cross-block pair as valid.
  # A pair with an unblocked trip has nothing to evaluate, because the rule reports
  # `:no_block` before it reaches the day types.
  defp both_service_day_types(day_types, rows, trips) do
    rows
    |> Enum.flat_map(fn row ->
      case blocked_trips(row, trips) do
        nil ->
          []

        {from, to} ->
          day_types
          |> DayTypes.containing(from.service_id)
          |> Enum.filter(&(to.service_id in &1.service_ids))
      end
    end)
    |> Enum.uniq_by(& &1.key)
  end

  # The two trips of a record when both are in hand and each names a block, and
  # `nil` otherwise: a missing trip or an unblocked pair has no order to read.
  defp blocked_trips(row, trips) do
    case Map.get(trips, row.from_trip_id) do
      %{block_id: block_id} = from when is_binary(block_id) ->
        case Map.get(trips, row.to_trip_id) do
          %{block_id: to_block_id} = to when is_binary(to_block_id) -> {from, to}
          _ -> nil
        end

      _ ->
        nil
    end
  end

  # The trips of both blocks the admitted records name, within the evaluated day
  # types' services: the rows R6 orders. Both block IDs are read so every evaluated
  # `{day key, block}` pair has its order, including the block of a cross-block
  # pair's second trip. Filtering by the services rather than by the dates and
  # collecting the IDs first keeps this one query.
  defp block_rows(organization_id, gtfs_version_id, day_types, rows, trips) do
    block_ids =
      rows
      |> Enum.flat_map(fn row ->
        case blocked_trips(row, trips) do
          nil -> []
          {from, to} -> [from.block_id, to.block_id]
        end
      end)
      |> Enum.uniq()

    service_ids = day_types |> Enum.flat_map(& &1.service_ids) |> Enum.uniq()

    Queries.trip_rows(organization_id, gtfs_version_id, {:blocks, block_ids, service_ids})
  end

  # `Checks.sequence/1` is the same order the rule reads, keyed by day type and
  # block ID for `{day key, block}`.
  defp sequences(day_types, block_rows) do
    block_ids = block_rows |> Enum.map(& &1.block_id) |> Enum.uniq()

    for day_type <- day_types,
        block_id <- block_ids,
        into: %{} do
      order =
        block_rows
        |> Enum.filter(&(&1.block_id == block_id and &1.service_id in day_type.service_ids))
        |> Checks.sequence()
        |> Enum.map(& &1.id)

      {{day_type.key, block_id}, order}
    end
  end

  # A block lists its trips in service order first, then the trips the sequence
  # leaves out (frequency-based and unplottable) by natural trip ID.
  defp order_block_trips(trips) do
    sequence = Checks.sequence(trips)
    sequenced = MapSet.new(sequence, & &1.id)

    rest =
      trips
      |> Enum.reject(&MapSet.member?(sequenced, &1.id))
      |> Enum.sort_by(& &1.trip_id)

    sequence ++ rest
  end

  # The pool lists its plottable trips by first departure and the untimed ones
  # last, so what can be assigned to a block is read top down.
  defp order_pool(pool_trips) do
    {plottable, untimed} = Enum.split_with(pool_trips, & &1.plottable?)

    Enum.sort_by(plottable, & &1.first_departure) ++ Enum.sort_by(untimed, & &1.trip_id)
  end

  defp pool_notices(pool_trips, min_layover_minutes) do
    Enum.flat_map(pool_trips, &Checks.block_findings(nil, [&1], min_layover_minutes))
  end

  # The axis covers every plottable trip of the day type, blocked or not, from the
  # floor hour of the earliest first departure to the ceiling hour of the latest
  # last arrival.
  defp axis(trips) do
    plottable = Enum.filter(trips, & &1.plottable?)

    case plottable do
      [] ->
        nil

      _ ->
        %{
          start_secs: floor_hour(plottable |> Enum.map(& &1.first_departure) |> Enum.min()),
          end_secs: ceil_hour(plottable |> Enum.map(& &1.last_arrival) |> Enum.max())
        }
    end
  end

  defp floor_hour(secs), do: div(secs, @seconds_per_hour) * @seconds_per_hour

  defp ceil_hour(secs) do
    if rem(secs, @seconds_per_hour) == 0 do
      secs
    else
      floor_hour(secs) + @seconds_per_hour
    end
  end
end
