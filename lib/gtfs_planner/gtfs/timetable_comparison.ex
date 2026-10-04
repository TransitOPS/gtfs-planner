defmodule GtfsPlanner.Gtfs.TimetableComparison do
  @moduledoc """
  The bounded, authorized feed snapshot one approved-timetable comparison is
  computed from.

  `load/2` reads the route's complete applicable feed rows inside one PostgreSQL
  `REPEATABLE READ READ ONLY` transaction and returns them as one
  digest-identified value. `compare/2` turns one accepted `Gtfs.TimetableSource`
  and that snapshot into one deterministic read-only report; `page/3` reads a
  page of retained witnesses out of that same report, and `fresh_digest/2` is the
  step 8 stale-state check that re-reads through the same loader. Nothing here
  writes, and nothing here calls a provider: the transaction is closed before
  the caller does anything else (CR-3, CL-5, INV-1, INV-3).

  ## The report

    * `totals` are exact and named by unit: `matched`, `missing` and `extra` count
      trip-date pairs, `time_mismatch` counts source-cell, event and date
      comparisons, and `date_mismatch` counts differing date memberships of one
      mapped trip and source row. The categories overlap by design and are never
      summed into an invented grand total.
    * `witnesses` retains at most 500 examples per category, sorted by date,
      source row, scoped trip id, occurrence sequence, event and category, while
      the totals above come from a reducer over every comparison. A bounded
      display is therefore never a bounded computation.
    * `computation` is `:incomplete` whenever the snapshot could not be read
      whole or a blocking unresolved item stands, so an incomplete computation
      can never read as all matched, and `clean?` additionally requires no
      unresolved item, no exclusion, no difference and at least one matched
      trip-date pair.
    * An unknown or not-served source clock, a feed clock that cannot be read, a
      mapped occurrence the trip does not board at, an unmapped source row, a
      duplicate feed trip, a calendar that contradicts the mapped trip and every
      `frequencies.txt` window are disclosed as `unresolved` or `exclusions`
      instead of being invented into exact matches (AC-12, INV-3).

  ## Contracts

    * `scope` is server-owned: `%{organization_id:, gtfs_version_id:, actor_id:,
      route_id:}`, all UUIDs, built from a host's own assigns and never from a
      tool argument. The actor's current editor membership and the scoped
      `published` version and route are re-read **inside** the transaction, so a
      membership withdrawn between two reads cannot expose a row.
    * `selection` is the reviewed comparison scope: the inclusive
      `{first_date, last_date}` interval plus optional reviewed `direction_ids`,
      `pattern_ids` and `service_ids`. `nil` for a selector means every value the
      route actually has for it, so a narrowing is always explicit. An interval
      longer than 366 inclusive dates is refused whole.
    * Work is bounded: at most 10,000 scoped trips and 75,000 scoped stop-time
      rows. Each is read with its own `LIMIT cap + 1` and refused as
      `{:error, {:incomplete, reason}}` when it is exceeded. Rows are never
      truncated, and no refusal ever carries a partial answer that could read as
      a clean comparison.
    * Effective service dates come from the shared
      `Calendars.ServiceDates.active_dates_between/4` with the calendar's weekly
      row and its additions and removals, so an exception-only calendar is still
      service and a removal wins over the weekly baseline. `GtfsTime.parse/1`
      reads `arrival_time` and `departure_time` separately and keeps values past
      24:00; the `ServiceQueries` departure-fallback helper is deliberately not
      used, because an arrival is not a departure.
    * The digest is the server's hash of the exact normalized rows this answer
      was computed from, so two reads of two different states cannot produce the
      same digest and a stale report can be detected by reloading (CL-5, FH-5).
  """

  import Ecto.Query, warn: false

  alias GtfsPlanner.Authorization
  alias GtfsPlanner.Gtfs.Calendar
  alias GtfsPlanner.Gtfs.CalendarDate
  alias GtfsPlanner.Gtfs.Calendars.ServiceDates
  alias GtfsPlanner.Gtfs.Frequency
  alias GtfsPlanner.Gtfs.GtfsTime
  alias GtfsPlanner.Gtfs.Route
  alias GtfsPlanner.Gtfs.RoutePattern
  alias GtfsPlanner.Gtfs.RoutePatternStop
  alias GtfsPlanner.Gtfs.ServiceQueries.Snapshot
  alias GtfsPlanner.Gtfs.StopTime
  alias GtfsPlanner.Gtfs.TimetableSource
  alias GtfsPlanner.Gtfs.Trip
  alias GtfsPlanner.Repo
  alias GtfsPlanner.Versions.GtfsVersion

  # Conservative engineering ceilings, not measured workloads. Each is enforced
  # by its own query's `LIMIT`, so an over-limit scope never materializes an
  # unbounded row set before it is refused.
  @max_dates 366
  @max_trips 10_000
  @max_stop_times 75_000

  # Frequency rows hang off scoped trips, so a per-trip ceiling derived from the
  # trip ceiling bounds them without inventing a scale promise.
  @max_frequencies @max_trips

  @published_status "published"

  # A bounded sample, not a bounded computation: the totals come from a reducer
  # over every comparison, and only the retained examples are truncated. The
  # page size is a quarter of the sample so one witness list cannot be read out
  # in a single request.
  @witness_limit 500
  @page_size 50

  @categories [:matched, :missing, :extra, :time_mismatch, :date_mismatch]

  @typedoc "Server-owned organization, version, actor and route identity."
  @type scope :: %{
          required(:organization_id) => Ecto.UUID.t(),
          required(:gtfs_version_id) => Ecto.UUID.t(),
          required(:actor_id) => Ecto.UUID.t(),
          required(:route_id) => Ecto.UUID.t()
        }

  @typedoc """
  The reviewed comparison scope. `interval` is `{first_date, last_date}`
  inclusive; each selector is `nil` (every value the route has) or a list of
  distinct reviewed values.
  """
  @type selection :: %{
          required(:interval) => {Date.t(), Date.t()},
          optional(:direction_ids) => [0 | 1] | nil,
          optional(:pattern_ids) => [String.t()] | nil,
          optional(:service_ids) => [String.t()] | nil
        }

  @typedoc "One stop occurrence of a route pattern, in the pattern's own order."
  @type pattern_occurrence :: %{stop_id: String.t(), position: non_neg_integer()}

  @typedoc "One scoped route pattern and every occurrence it boards at."
  @type pattern :: %{
          route_pattern_id: String.t(),
          name: String.t() | nil,
          direction_id: 0 | 1 | nil,
          headsign: String.t() | nil,
          occurrences: [pattern_occurrence()]
        }

  @typedoc "One scoped trip, with the service dates it actually runs."
  @type trip :: %{
          trip_id: String.t(),
          service_id: String.t(),
          direction_id: 0 | 1 | nil,
          headsign: String.t() | nil,
          short_name: String.t() | nil,
          pattern_id: String.t() | nil,
          service_dates: [Date.t()]
        }

  @typedoc """
  One scoped stop time. `arrival_secs` and `departure_secs` are read separately
  and are independently `nil` when the retained value cannot be parsed, so an
  unreadable arrival is never filled in from the departure.
  """
  @type stop_time :: %{
          trip_id: String.t(),
          stop_id: String.t(),
          stop_sequence: integer(),
          arrival_time: String.t() | nil,
          departure_time: String.t() | nil,
          arrival_secs: non_neg_integer() | nil,
          departure_secs: non_neg_integer() | nil,
          timepoint: integer() | nil,
          pickup_type: integer() | nil,
          drop_off_type: integer() | nil
        }

  @typedoc "One `frequencies.txt` row, kept as a window and never expanded here."
  @type frequency :: %{
          trip_id: String.t(),
          start_secs: non_neg_integer() | nil,
          end_secs: non_neg_integer() | nil,
          headway_secs: pos_integer() | nil,
          exact_times: 0 | 1
        }

  @typedoc "The weekly row, exceptions and effective dates of one scoped service."
  @type service :: %{
          service_id: String.t(),
          weekly:
            %{
              monday: integer(),
              tuesday: integer(),
              wednesday: integer(),
              thursday: integer(),
              friday: integer(),
              saturday: integer(),
              sunday: integer(),
              start_date: Date.t(),
              end_date: Date.t()
            }
            | nil,
          exceptions: [%{date: Date.t(), exception_type: 1 | 2}],
          active_dates: [Date.t()]
        }

  @typedoc """
  Everything one comparison is computed from, plus the digest that identifies it.

  `completeness` is `:incomplete` when a scoped calendar could not be read, so a
  caller can never derive a clean verdict from it.
  """
  @type inputs :: %{
          scope: %{
            organization_id: Ecto.UUID.t(),
            gtfs_version_id: Ecto.UUID.t(),
            route_id: Ecto.UUID.t()
          },
          route: %{
            id: Ecto.UUID.t(),
            route_id: String.t(),
            state: :active | :inactive,
            agency_id: String.t() | nil
          },
          selection: selection(),
          interval: {Date.t(), Date.t()},
          services: %{optional(String.t()) => service()},
          service_ids: [String.t()],
          trips: [trip()],
          stop_times: [stop_time()],
          frequencies: [frequency()],
          patterns: [pattern()],
          unreadable_service_ids: [String.t()],
          totals: %{
            trips: non_neg_integer(),
            stop_times: non_neg_integer(),
            frequencies: non_neg_integer()
          },
          completeness: :complete | :incomplete,
          feed_digest: String.t()
        }

  @typedoc """
  One retained comparison example. `date`, `source_row_id`, `trip_id`,
  `stop_sequence` and `event` are the sort key; `reason` says what differs and
  `source_clock`/`feed_clock` carry the two service-day second readings a
  display needs to show the difference.
  """
  @type witness :: %{
          category: atom(),
          date: Date.t(),
          source_row_id: non_neg_integer(),
          trip_id: String.t(),
          service_id: String.t(),
          stop_id: String.t() | nil,
          stop_sequence: non_neg_integer() | nil,
          event: :arrival | :departure | nil,
          source_clock: integer() | nil,
          feed_clock: integer() | nil,
          reason: atom()
        }

  @typedoc """
  One read-only comparison. `witnesses` is the bounded retained sample per
  category; `totals` is the exact full computation, so a display limit never
  reads as a complete answer (AC-13, INV-3).
  """
  @type report :: %{
          source_digest: String.t(),
          feed_digest: String.t(),
          interval: {Date.t(), Date.t()},
          comparison_scope: map(),
          computation: :complete | :incomplete,
          clean?: boolean(),
          totals: %{optional(atom()) => non_neg_integer()},
          units: %{optional(atom()) => String.t()},
          witnesses: %{optional(atom()) => [witness()]},
          unresolved: [term()],
          exclusions: [term()]
        }

  @type error ::
          :not_accepted
          | :forbidden
          | :not_found
          | :invalid_selection
          | {:incomplete, {:too_many_dates, pos_integer()}}
          | {:incomplete, {:too_many_trips, pos_integer()}}
          | {:incomplete, {:too_many_stop_times, pos_integer()}}
          | {:incomplete, {:too_many_frequencies, pos_integer()}}

  @doc """
  Returns the loader's work ceilings, so the bound a caller is told about and the
  bound the queries enforce cannot drift apart.

  At most 366 inclusive dates, 10,000 scoped trips and 75,000 scoped stop-time
  rows. A larger scope is refused as `{:error, {:incomplete, reason}}` and is
  never truncated into a partial answer.
  """
  @spec limits() :: %{dates: pos_integer(), trips: pos_integer(), stop_times: pos_integer()}
  def limits, do: %{dates: @max_dates, trips: @max_trips, stop_times: @max_stop_times}

  @doc """
  Loads the route's complete applicable feed rows for one reviewed comparison
  scope.

  `scope` is the server-owned organization, version, actor and route; `selection`
  is `%{interval: {first_date, last_date}}` plus optional reviewed
  `direction_ids`, `pattern_ids` and `service_ids`. The actor's current editor
  membership, the scoped `published` version and the route are all checked
  inside the one read transaction, before any row is returned.

  Returns `{:ok, inputs}`, or one of:

    * `{:error, :forbidden}` — the actor has no current editor membership.
    * `{:error, :not_found}` — the version is not a published version of that
      organization, or the route is not in it.
    * `{:error, :invalid_selection}` — a malformed interval or selector.
    * `{:error, {:incomplete, reason}}` — the scope exceeds a work ceiling, so
      nothing was computed and nothing may read as a clean comparison.

  No model request is ever made while the snapshot is held.
  """
  @spec load(scope(), selection()) :: {:ok, inputs()} | {:error, error()}
  def load(scope, selection) when is_map(scope) and is_map(selection) do
    with {:ok, scoped} <- scoped(scope),
         {:ok, bounded} <- comparison_selection(selection) do
      in_snapshot(fn -> comparison_answer(scoped, bounded) end)
    end
  end

  def load(_scope, _selection), do: {:error, :invalid_selection}

  @doc """
  Reconciles one accepted `Gtfs.TimetableSource` against the feed snapshot.

  The comparison scope is derived from the source itself: its own inclusive
  interval is the window, and its rows' reviewed `pattern_id` and `direction_id`
  narrow the feed. Nothing is widened by a guess and nothing is narrowed away
  silently — every trip-date pair in the requested scope is either matched,
  missing or extra.

  Returns `{:ok, report}`, or `{:error, :not_accepted}` when the source was not
  explicitly accepted, plus every refusal `load/2` can return. The loader's
  `{:error, {:incomplete, reason}}` is passed through unchanged, so a capped
  comparison is never answered with a partial verdict.

  The report's `computation` is `:incomplete` whenever the snapshot was
  incomplete, a blocking unresolved item stands, or an unmapped source row could
  not be compared at all; only a complete computation with no unresolved item,
  no exclusion, no difference and at least one matched pair is `clean?`.
  """
  @spec compare(scope(), TimetableSource.source()) :: {:ok, report()} | {:error, error()}
  def compare(scope, %{accepted?: true} = source) when is_map(scope) do
    with {:ok, selection} <- selection_of(source),
         {:ok, inputs} <- load(scope, selection) do
      {:ok, build_report(inputs, source)}
    end
  end

  def compare(_scope, _source), do: {:error, :not_accepted}

  @doc """
  Returns one page of retained witnesses for a report category.

  Fifty witnesses per page, read out of the report the caller already holds: the
  page never re-reads the feed, so paging cannot answer from a different
  snapshot than the totals beside it. `retained` and `total` say how much of the
  category the bounded sample kept, so a full page never implies a complete
  category.
  """
  @spec page(report(), atom(), pos_integer()) ::
          {:ok, map()} | {:error, :unknown_category | :invalid_page}
  def page(report, category, page_number)
      when is_map(report) and is_atom(category) and is_integer(page_number) and page_number >= 1 do
    case get_in(report, [:witnesses, category]) do
      witnesses when is_list(witnesses) ->
        {:ok,
         %{
           category: category,
           page: page_number,
           page_size: @page_size,
           retained: length(witnesses),
           total: get_in(report, [:totals, category]) || length(witnesses),
           witnesses: Enum.slice(witnesses, (page_number - 1) * @page_size, @page_size)
         }}

      _absent ->
        {:error, :unknown_category}
    end
  end

  def page(_report, _category, _page_number), do: {:error, :invalid_page}

  @doc """
  Returns the current full feed digest for the same scope and source.

  Step 8's stale-state check re-reads through the same loader and compares this
  digest with the report's `feed_digest`. A feed change moves the digest because
  it hashes the exact rows read, not a timestamp or a row count, so an unchanged
  digest really does describe unchanged content.
  """
  @spec fresh_digest(scope(), TimetableSource.source()) ::
          {:ok, String.t()} | {:error, error()}
  def fresh_digest(scope, %{accepted?: true} = source) when is_map(scope) do
    with {:ok, selection} <- selection_of(source),
         {:ok, inputs} <- load(scope, selection) do
      {:ok, inputs.feed_digest}
    end
  end

  def fresh_digest(_scope, _source), do: {:error, :not_accepted}

  # -- scope of one comparison ------------------------------------------------

  # The source's own interval is the window; its rows name the pattern and
  # direction that were reviewed, so the feed is narrowed to what the editor
  # actually looked at. A source whose rows name no pattern or direction keeps
  # every value the route has for it, which is the same reviewed-everything
  # reading the loader already uses for an absent selector.
  defp selection_of(%{interval: {first, last}, rows: rows}) do
    pattern_ids = rows |> Enum.map(& &1.pattern_id) |> Enum.reject(&is_nil/1) |> Enum.uniq()
    direction_ids = rows |> Enum.map(& &1.direction_id) |> Enum.reject(&is_nil/1) |> Enum.uniq()

    {:ok,
     %{
       interval: {first, last},
       direction_ids: if(direction_ids == [], do: nil, else: Enum.sort(direction_ids)),
       pattern_ids: if(pattern_ids == [], do: nil, else: Enum.sort(pattern_ids)),
       service_ids: nil
     }}
  end

  defp selection_of(_source), do: {:error, :invalid_selection}

  # -- the report -------------------------------------------------------------

  # Incomplete means the whole reviewed scope could not be computed: an
  # unreadable retained calendar, or a blocking unresolved item standing beside
  # the totals. A witness sample that was truncated is not incomplete, because
  # its totals are exact (AC-13).
  defp build_report(inputs, source) do
    counted = count_rows(inputs, source)
    unresolved = MapSet.union(counted.unresolved, MapSet.new(source.unresolved))
    exclusions = MapSet.union(counted.exclusions, MapSet.new(source.exclusions))
    blocking? = Enum.any?(unresolved, &TimetableSource.blocking_reason?/1)

    totals = Map.merge(Map.new(@categories, &{&1, 0}), counted.totals)

    computation =
      if inputs.completeness == :complete and not blocking?, do: :complete, else: :incomplete

    %{
      source_digest: source.digest,
      feed_digest: inputs.feed_digest,
      interval: inputs.interval,
      comparison_scope: comparison_scope(inputs, source),
      computation: computation,
      clean?: clean?(computation, totals, unresolved, exclusions),
      totals: totals,
      units: units(),
      witnesses: counted.kept,
      unresolved: sorted_reasons(unresolved),
      exclusions: sorted_reasons(exclusions)
    }
  end

  defp sorted_reasons(reasons) do
    reasons |> Enum.sort_by(&inspect/1) |> Enum.to_list()
  end

  defp comparison_scope(inputs, source) do
    %{
      route_id: inputs.route.route_id,
      direction_ids: inputs.selection.direction_ids,
      pattern_ids: inputs.selection.pattern_ids,
      source_rows: length(source.rows),
      feed_trips: inputs.totals.trips
    }
  end

  # The unit of every category is named in the report, because these totals
  # overlap and must never be summed into one number (AC-13).
  defp units do
    %{
      matched: "trip-date pairs",
      missing: "trip-date pairs",
      extra: "trip-date pairs",
      time_mismatch: "source cell, event and date comparisons",
      date_mismatch: "mapped trip and source row date differences"
    }
  end

  # Only a complete computation with nothing unresolved, nothing excluded, no
  # difference in any category and at least one actually compared pair is
  # clean: an empty or capped comparison is never an all-match.
  defp clean?(:complete, totals, unresolved, exclusions) do
    Enum.empty?(unresolved) and Enum.empty?(exclusions) and
      Enum.all?(@categories -- [:matched], &(Map.get(totals, &1) == 0)) and
      Map.get(totals, :matched, 0) > 0
  end

  defp clean?(:incomplete, _totals, _unresolved, _exclusions), do: false

  # -- classification ---------------------------------------------------------

  # Every observation is folded through one accumulator: counts rise for every
  # comparison while only the earliest 500 witnesses per category are kept.
  # Nothing here builds the full 366 x 75,000 cross product, so the totals stay
  # exact at the ceiling and the memory stays bounded (AC-13).
  defp count_rows(inputs, source) do
    trips = Map.new(inputs.trips, &{&1.trip_id, &1})
    stop_times = stop_time_index(inputs.stop_times)
    frequency_trips = MapSet.new(Enum.map(inputs.frequencies, & &1.trip_id))

    {mapped, state} =
      source.rows
      |> Enum.sort_by(& &1.source_row_id)
      |> Enum.reduce({MapSet.new(), new_state()}, fn row, {mapped, state} ->
        {mapped, state} = count_row(row, trips, stop_times, frequency_trips, mapped, state)
        {mapped, state}
      end)

    state
    |> count_unmapped_trips(trips, frequency_trips, mapped)
    |> exclude_frequencies(inputs.frequencies)
    |> Map.update!(:kept, fn kept ->
      # `:gb_trees.values/1` is already in key order, which is the documented
      # witness sort order, so the bounded samples become ordered lists here.
      Map.new(kept, fn {category, tree} -> {category, :gb_trees.values(tree)} end)
    end)
  end

  # A row only claims a feed trip when its reviewed mapping resolved one, so a
  # source row with no mapping is disclosed as unresolved rather than turned into
  # a difference it cannot support.
  defp count_row(row, trips, stop_times, frequency_trips, mapped, state) do
    trip_id = row.feed_trip_id

    cond do
      is_nil(trip_id) ->
        {mapped, add_unresolved(state, {:unmapped_source_row, row.source_row_id})}

      # Two source rows mapped to one trip would compare it twice; that is
      # disclosed, never deduplicated (AC-12).
      MapSet.member?(mapped, trip_id) ->
        {mapped, add_unresolved(state, {:duplicate_feed_trip, row.source_row_id, trip_id})}

      not Map.has_key?(trips, trip_id) ->
        {mapped, add_unresolved(state, {:unknown_feed_trip, row.source_row_id, trip_id})}

      MapSet.member?(frequency_trips, trip_id) ->
        # Its templates are excluded once below, not expanded into matches.
        {MapSet.put(mapped, trip_id), state}

      true ->
        {MapSet.put(mapped, trip_id),
         count_pair_dates(row, Map.fetch!(trips, trip_id), stop_times, state)}
    end
  end

  # One mapped row's trip-date pairs: dates the feed runs but the row does not
  # list are missing, dates the row lists but the feed does not run are extra,
  # and each of those also receives the explicit date-difference witness. The
  # dates both agree on are compared occurrence by occurrence.
  defp count_pair_dates(row, trip, stop_times, state) do
    source_dates = MapSet.new(row.dates)
    feed_dates = MapSet.new(trip.service_dates)

    state =
      Enum.reduce(sorted_dates(MapSet.difference(feed_dates, source_dates)), state, fn date,
                                                                                       state ->
        state
        |> witness(:missing, date_detail(date, row, trip, :missing_on_date))
        |> witness(:date_mismatch, date_detail(date, row, trip, :missing_on_date))
      end)

    state =
      Enum.reduce(sorted_dates(MapSet.difference(source_dates, feed_dates)), state, fn date,
                                                                                       state ->
        state
        |> witness(:extra, date_detail(date, row, trip, :extra_on_date))
        |> witness(:date_mismatch, date_detail(date, row, trip, :extra_on_date))
      end)

    Enum.reduce(
      sorted_dates(MapSet.intersection(source_dates, feed_dates)),
      state,
      &count_shared_date(&2, row, trip, &1, stop_times)
    )
  end

  # Every event of every mapped occurrence on one shared date. A supplied integer
  # clock that differs from the feed's own separately parsed clock is a time
  # mismatch; a source `:unknown` or `:not_served` clock, an absent mapped
  # occurrence and an unreadable feed clock are unresolved, so the pair cannot
  # match and never reads as equal (AC-11, AC-12).
  defp count_shared_date(state, row, trip, date, stop_times) do
    {state, matched?} =
      row.cells
      |> Enum.sort_by(&occurrence_key(&1.occurrence))
      |> Enum.reduce({state, true}, &count_shared_cell(&1, &2, row, trip, date, stop_times))

    count_matched_pair({state, matched?}, row, trip, date)
  end

  defp count_shared_cell(cell, {state, matched?}, row, trip, date, stop_times) do
    occurrence = cell.occurrence
    key = {trip.trip_id, occurrence.stop_id, occurrence.stop_sequence}

    case Map.fetch(stop_times, key) do
      :error ->
        {add_unresolved(state, missing_occurrence(row, occurrence)), false}

      {:ok, feed} ->
        [{:arrival, cell.arrival}, {:departure, cell.departure}]
        |> Enum.reduce(
          {state, matched?},
          &compare_supplied_event(&1, &2, row, trip, date, occurrence, feed)
        )
    end
  end

  # A side the source did not supply is not a comparison at all: it neither
  # matches nor differs, so it leaves the pair's running state untouched.
  defp compare_supplied_event({_event, nil}, acc, _row, _trip, _date, _occurrence, _feed), do: acc

  defp compare_supplied_event(
         {event, value},
         {state, matched?},
         row,
         trip,
         date,
         occurrence,
         feed
       ) do
    context = %{
      row: row,
      trip: trip,
      date: date,
      occurrence: occurrence,
      event: event,
      feed: feed
    }

    compare_event(state, context, value, matched?)
  end

  defp compare_event(state, context, value, matched?) do
    %{row: row, trip: trip, date: date, occurrence: occurrence, event: event, feed: feed} =
      context

    feed_secs = Map.get(feed, event_key(event))
    # `event` stays `:arrival`/`:departure` for the witness and the unresolved
    # reason; only the feed lookup uses the loader's own key.

    cond do
      value == :unknown ->
        {add_unresolved(state, unknown_clock(row, occurrence, event, :unknown_source_clock)),
         false}

      value == :not_served ->
        # A source that says no service is not equal to a real feed clock, and
        # it is not a difference either: nobody stated a time.
        {add_unresolved(state, unknown_clock(row, occurrence, event, :not_served_source_clock)),
         false}

      not is_integer(value) ->
        {add_unresolved(state, unknown_clock(row, occurrence, event, :unknown_source_clock)),
         false}

      is_nil(feed_secs) ->
        # The retained feed value cannot be read, so the pair stays unknown
        # rather than borrowing the other event's clock.
        {add_unresolved(state, unknown_clock(row, occurrence, event, :unreadable_feed_clock)),
         false}

      feed_secs == value ->
        # Service-day seconds, so 24:10 and 00:10 stay different clocks.
        {state, matched?}

      true ->
        {witness(
           state,
           :time_mismatch,
           event_detail(date, row, trip, occurrence, event, :clock_differs, value, feed_secs)
         ), false}
    end
  end

  # A trip-date pair is matched only when every event of every mapped occurrence
  # resolved and equalled the feed, so one differing clock withholds the pair
  # instead of counting it twice.
  defp count_matched_pair({state, true}, row, trip, date) do
    witness(state, :matched, date_detail(date, row, trip, :all_clocks_equal))
  end

  # The pair did not match, so it contributes a difference or an unresolved
  # reason that was already counted, never a matched pair.
  defp count_matched_pair({state, false}, _row, _trip, _date), do: state

  # A feed trip the source never mapped is missing on every date it runs: the
  # missing/extra set difference is over the requested scope, not only over the
  # rows the editor happened to paste (AC-10).
  defp count_unmapped_trips(state, trips, frequency_trips, mapped) do
    Enum.reduce(trips, state, &count_unmapped_trip(&1, &2, frequency_trips, mapped))
  end

  defp count_unmapped_trip({_trip_id, trip}, state, frequency_trips, mapped) do
    if MapSet.member?(mapped, trip.trip_id) or MapSet.member?(frequency_trips, trip.trip_id) or
         trip.service_dates == [] do
      state
    else
      Enum.reduce(sorted_dates(MapSet.new(trip.service_dates)), state, fn date, state ->
        witness(state, :missing, date_detail(date, nil, trip, :unmapped_feed_trip))
      end)
    end
  end

  # A frequency window is a typed exclusion and an unresolved template. Neither
  # the exact nor the non-exact window is expanded into invented source matches,
  # and a trip carrying one is left out of matched, missing and extra entirely, so
  # a template can neither fake a difference nor fake a match (AC-12).
  defp exclude_frequencies(state, frequencies) do
    Enum.reduce(frequencies, state, fn frequency, state ->
      state
      |> add_exclusion(
        {:frequency_template, frequency.trip_id, frequency.start_secs, frequency.end_secs,
         frequency.headway_secs, frequency.exact_times}
      )
      |> add_unresolved({:frequency_template, frequency.trip_id, frequency.exact_times})
    end)
  end

  defp missing_occurrence(row, occurrence) do
    {:missing_occurrence, row.source_row_id, row.feed_trip_id, occurrence.stop_id,
     occurrence.stop_sequence}
  end

  defp unknown_clock(row, occurrence, event, reason) do
    {reason, row.source_row_id, row.feed_trip_id, occurrence.stop_id, occurrence.stop_sequence,
     event}
  end

  defp event_key(:arrival), do: :arrival_secs
  defp event_key(:departure), do: :departure_secs

  # -- accumulation -----------------------------------------------------------

  # The retained sample is an ordered map per category, keyed by the witness sort
  # key, so the sample is always the first 500 *of the comparison*, not the first
  # 500 the fold happened to reach. `gb_trees` is the standard library's ordered
  # map: insert and drop-largest are both logarithmic, so the bound holds at a
  # possible 3.66 million comparisons without materializing them.
  defp new_state do
    %{
      totals: %{},
      kept: Map.new(@categories, &{&1, :gb_trees.empty()}),
      unresolved: MapSet.new(),
      exclusions: MapSet.new()
    }
  end

  defp bump(state, category, amount) do
    %{state | totals: Map.update(state.totals, category, amount, &(&1 + amount))}
  end

  # A witness is counted always and retained in the bounded ordered sample, so
  # the totals stay exact above the display limit.
  defp witness(state, category, details) do
    witness = details |> Map.put(:category, category) |> witness_witness()

    state
    |> bump(category, 1)
    |> add_witness(category, witness)
  end

  # `details` names the pair and the difference; everything a display needs
  # beyond that is filled here, so no call site can leave a witness half-built.
  defp witness_witness(details) do
    occurrence = Map.get(details, :occurrence)
    row = Map.get(details, :row)
    trip = Map.fetch!(details, :trip)

    %{
      category: Map.fetch!(details, :category),
      date: Map.fetch!(details, :date),
      source_row_id: if(row, do: row.source_row_id, else: 0),
      trip_id: trip.trip_id,
      service_id: trip.service_id,
      stop_id: occurrence && occurrence.stop_id,
      stop_sequence: occurrence && occurrence.stop_sequence,
      event: Map.get(details, :event),
      source_clock: Map.get(details, :source_clock),
      feed_clock: Map.get(details, :feed_clock),
      reason: Map.fetch!(details, :reason)
    }
  end

  defp date_detail(date, row, trip, reason) do
    %{date: date, row: row, trip: trip, reason: reason}
  end

  defp event_detail(date, row, trip, occurrence, event, reason, source_clock, feed_clock) do
    %{
      date: date,
      row: row,
      trip: trip,
      occurrence: occurrence,
      event: event,
      reason: reason,
      source_clock: source_clock,
      feed_clock: feed_clock
    }
  end

  defp add_witness(state, category, witness) do
    tree = state.kept |> Map.fetch!(category) |> retain(witness)
    %{state | kept: Map.put(state.kept, category, tree)}
  end

  # Insert, then drop the largest key once the sample is full. Both operations
  # are logarithmic, and the dropped witness is the last one of the whole
  # comparison, not the first one the fold reached.
  defp retain(tree, witness) do
    tree = :gb_trees.insert(witness_key(witness), witness, tree)

    if :gb_trees.size(tree) > @witness_limit do
      {largest, _dropped} = :gb_trees.largest(tree)
      :gb_trees.delete(largest, tree)
    else
      tree
    end
  end

  # Reasons are deduplicated as they are recorded, so a per-occurrence unknown
  # repeated across every reviewed date is one disclosed reason rather than one
  # entry per date.
  defp add_unresolved(state, reason),
    do: %{state | unresolved: MapSet.put(state.unresolved, reason)}

  defp add_exclusion(state, reason),
    do: %{state | exclusions: MapSet.put(state.exclusions, reason)}

  # A feed trip with no source row has no row to sort on, so `witness_witness/1`
  # gives it source row zero and its scoped trip id as the tiebreak.
  defp witness_key(witness) do
    {
      {witness.date.year, witness.date.month, witness.date.day},
      witness.source_row_id,
      witness.trip_id,
      witness.stop_sequence || 0,
      event_rank(witness.event),
      to_string(witness.reason)
    }
  end

  defp event_rank(:arrival), do: 0
  defp event_rank(:departure), do: 1
  defp event_rank(_event), do: 2

  defp occurrence_key(occurrence), do: {occurrence.stop_id, occurrence.stop_sequence}

  defp sorted_dates(dates), do: Enum.sort_by(dates, &{&1.year, &1.month, &1.day})

  # Both clocks are read from the loader's separately parsed values; neither is
  # derived from the other, and the `ServiceQueries` departure fallback is not
  # used because an arrival is not a departure.
  defp stop_time_index(stop_times) do
    Map.new(stop_times, fn row ->
      {{row.trip_id, row.stop_id, row.stop_sequence},
       %{arrival_secs: row.arrival_secs, departure_secs: row.departure_secs}}
    end)
  end

  # -- snapshot boundary ------------------------------------------------------

  # Every read of one answer, including the membership and scope checks that
  # authorize it, happens inside this transaction, and the digest is derived
  # from the rows it returned. The transaction is closed before the caller
  # builds a model request, so no provider call is ever made while it is held.
  defp in_snapshot(fun) when is_function(fun, 0) do
    Repo.transaction(
      fn ->
        snapshot_module().begin_read()
        fun.()
      end,
      timeout: :infinity
    )
    |> case do
      {:ok, {:ok, result}} -> {:ok, result}
      {:ok, {:error, reason}} -> {:error, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  defp snapshot_module do
    Application.get_env(:gtfs_planner, :gtfs_service_query_snapshot, Snapshot.Repo)
  end

  # -- scope and selection ---------------------------------------------------

  defp scoped(scope) do
    with {:ok, organization_id} <- uuid(Map.get(scope, :organization_id)),
         {:ok, gtfs_version_id} <- uuid(Map.get(scope, :gtfs_version_id)),
         {:ok, actor_id} <- uuid(Map.get(scope, :actor_id)),
         {:ok, route_id} <- uuid(Map.get(scope, :route_id)) do
      {:ok,
       %{
         organization_id: organization_id,
         gtfs_version_id: gtfs_version_id,
         actor_id: actor_id,
         route_id: route_id
       }}
    else
      _other -> {:error, :not_found}
    end
  end

  defp uuid(value) do
    case Ecto.UUID.cast(value) do
      {:ok, id} -> {:ok, id}
      :error -> {:error, :not_found}
    end
  end

  defp comparison_selection(selection) do
    interval = Map.get(selection, :interval)

    with {:ok, bounded_interval} <- bounded_interval(interval),
         {:ok, direction_ids} <- directions(Map.get(selection, :direction_ids)),
         {:ok, pattern_ids} <- ids(Map.get(selection, :pattern_ids)),
         {:ok, service_ids} <- ids(Map.get(selection, :service_ids)) do
      {:ok,
       %{
         interval: bounded_interval,
         direction_ids: direction_ids,
         pattern_ids: pattern_ids,
         service_ids: service_ids
       }}
    end
  end

  defp bounded_interval({%Date{} = first, %Date{} = last}) do
    case Date.compare(first, last) do
      :gt ->
        {:error, :invalid_selection}

      _other ->
        count = Date.diff(last, first) + 1

        if count > @max_dates do
          {:error, {:incomplete, {:too_many_dates, count}}}
        else
          {:ok, {first, last}}
        end
    end
  end

  defp bounded_interval(_interval), do: {:error, :invalid_selection}

  defp directions(nil), do: {:ok, nil}

  defp directions(direction_ids) when is_list(direction_ids) do
    if direction_ids != [] and Enum.all?(direction_ids, &(&1 in [0, 1])) and
         length(Enum.uniq(direction_ids)) == length(direction_ids) do
      {:ok, Enum.sort(direction_ids)}
    else
      {:error, :invalid_selection}
    end
  end

  defp directions(_direction_ids), do: {:error, :invalid_selection}

  defp ids(nil), do: {:ok, nil}

  defp ids(values) when is_list(values) do
    if values != [] and Enum.all?(values, &nonblank?/1) and
         length(Enum.uniq(values)) == length(values) do
      {:ok, Enum.sort(values)}
    else
      {:error, :invalid_selection}
    end
  end

  defp ids(_values), do: {:error, :invalid_selection}

  defp nonblank?(value), do: is_binary(value) and String.trim(value) != ""

  # -- the answer -------------------------------------------------------------

  defp comparison_answer(scoped, selection) do
    with :ok <- authorize(scoped),
         {:ok, route} <- published_route(scoped),
         {:ok, trip_rows, service_ids} <- scoped_trips(scoped, route, selection),
         {:ok, stop_time_rows} <- scoped_stop_times(scoped, trip_rows),
         {:ok, frequency_rows} <- scoped_frequencies(scoped, trip_rows),
         {:ok, patterns} <- scoped_patterns(scoped, route, selection, trip_rows) do
      {:ok,
       inputs(
         scoped,
         route,
         selection,
         trip_rows,
         service_ids,
         stop_time_rows,
         frequency_rows,
         patterns
       )}
    end
  end

  # The membership is re-read here, inside the snapshot transaction, so an access
  # withdrawn after the conversation started stops this read too (INV-1).
  defp authorize(scoped) do
    case Authorization.authorize_editor(%{
           actor_id: scoped.actor_id,
           organization_id: scoped.organization_id
         }) do
      :ok -> :ok
      {:error, :forbidden} -> {:error, :forbidden}
    end
  end

  # An unpublished version and a foreign or absent route are the same refusal, so
  # no other tenant's metadata is disclosed.
  defp published_route(scoped) do
    version =
      from(v in GtfsVersion,
        where:
          v.id == ^scoped.gtfs_version_id and v.organization_id == ^scoped.organization_id and
            v.publication_status == ^@published_status
      )

    case Repo.one(version) do
      nil ->
        {:error, :not_found}

      %GtfsVersion{} ->
        route =
          from(r in Route,
            where:
              r.id == ^scoped.route_id and r.organization_id == ^scoped.organization_id and
                r.gtfs_version_id == ^scoped.gtfs_version_id
          )

        case Repo.one(route) do
          %Route{} = found -> {:ok, found}
          nil -> {:error, :not_found}
        end
    end
  end

  defp scoped_trips(scoped, %Route{} = route, selection) do
    trips =
      Trip
      |> scoped_to_route(scoped, route)
      |> narrowed(:direction_id, selection.direction_ids)
      |> narrowed(:route_pattern_id, selection.pattern_ids)
      |> narrowed(:service_id, selection.service_ids)
      |> order_by([t], asc: t.trip_id, asc: t.id)
      |> Repo.all(limit: @max_trips + 1)

    case trips do
      [_ | _] = loaded when length(loaded) > @max_trips ->
        {:error, {:incomplete, {:too_many_trips, length(loaded)}}}

      _loaded ->
        {:ok, trips, trips |> Enum.map(& &1.service_id) |> Enum.uniq() |> Enum.sort()}
    end
  end

  defp scoped_to_route(query, scoped, %Route{route_id: route_id}) do
    from(t in query,
      where:
        t.organization_id == ^scoped.organization_id and
          t.gtfs_version_id == ^scoped.gtfs_version_id and t.route_id == ^route_id
    )
  end

  # A reviewed selector narrows the scoped route; an absent one keeps every value
  # the route has, so the widened scope is never a guess about which trips matter.
  defp narrowed(query, _field, nil), do: query
  defp narrowed(query, field, values), do: from(t in query, where: field(t, ^field) in ^values)

  defp scoped_stop_times(scoped, trips) do
    case trip_ids(trips) do
      [] ->
        {:ok, []}

      trip_ids ->
        rows =
          from(s in StopTime,
            where:
              s.organization_id == ^scoped.organization_id and
                s.gtfs_version_id == ^scoped.gtfs_version_id and s.trip_id in ^trip_ids,
            order_by: [asc: s.trip_id, asc: s.stop_sequence, asc: s.id],
            limit: @max_stop_times + 1
          )
          |> Repo.all()

        case rows do
          [_ | _] = loaded when length(loaded) > @max_stop_times ->
            {:error, {:incomplete, {:too_many_stop_times, length(loaded)}}}

          _loaded ->
            {:ok, rows}
        end
    end
  end

  defp scoped_frequencies(scoped, trips) do
    case trip_ids(trips) do
      [] ->
        {:ok, []}

      trip_ids ->
        rows =
          from(f in Frequency,
            where:
              f.organization_id == ^scoped.organization_id and
                f.gtfs_version_id == ^scoped.gtfs_version_id and f.trip_id in ^trip_ids,
            order_by: [asc: f.trip_id, asc: f.start_time, asc: f.id],
            limit: @max_frequencies + 1
          )
          |> Repo.all()

        case rows do
          [_ | _] = loaded when length(loaded) > @max_frequencies ->
            {:error, {:incomplete, {:too_many_frequencies, length(loaded)}}}

          _loaded ->
            {:ok, rows}
        end
    end
  end

  defp trip_ids([]), do: []
  defp trip_ids(trips), do: trips |> Enum.map(& &1.trip_id) |> Enum.uniq()

  # Patterns are the reviewed scope's own vocabulary: with reviewed pattern ids
  # the route must actually have every one of them, and with none every pattern
  # the scoped trips use is loaded. A narrowing is never silently widened and a
  # pattern the route does not run is refused rather than read from another
  # scope.
  defp scoped_patterns(scoped, %Route{} = route, selection, trips) do
    route_patterns =
      from(p in RoutePattern,
        where:
          p.organization_id == ^scoped.organization_id and
            p.gtfs_version_id == ^scoped.gtfs_version_id and p.route_id == ^route.route_id,
        order_by: [asc: p.route_pattern_id, asc: p.id]
      )
      |> Repo.all()

    requested =
      case selection.pattern_ids do
        nil -> trip_pattern_ids(trips)
        ids -> ids
      end

    case requested do
      [] ->
        {:ok, []}

      requested ->
        known = route_patterns |> Enum.map(& &1.route_pattern_id) |> Enum.uniq()

        if selection.pattern_ids != nil and not Enum.all?(requested, &(&1 in known)) do
          {:error, :not_found}
        else
          selected = Enum.filter(route_patterns, &(&1.route_pattern_id in requested))
          {:ok, attach_occurrences(scoped, selected, known)}
        end
    end
  end

  defp trip_pattern_ids([]), do: []

  defp trip_pattern_ids(trips),
    do: trips |> Enum.map(& &1.route_pattern_id) |> Enum.reject(&is_nil/1) |> Enum.uniq()

  defp attach_occurrences(_scoped, [], _pattern_ids), do: []

  # `RoutePatternStop.route_pattern_id` is the pattern row's own UUID, so the
  # occurrences are read by that identity and reported under the GTFS pattern id
  # the reviewed selection named.
  defp attach_occurrences(scoped, patterns, _pattern_ids) do
    occurrences =
      from(o in RoutePatternStop,
        where:
          o.organization_id == ^scoped.organization_id and
            o.gtfs_version_id == ^scoped.gtfs_version_id and
            o.route_pattern_id in ^Enum.map(patterns, & &1.id),
        order_by: [asc: o.route_pattern_id, asc: o.position, asc: o.id],
        select: %{route_pattern_id: o.route_pattern_id, stop_id: o.stop_id, position: o.position}
      )
      |> Repo.all()
      |> Enum.group_by(& &1.route_pattern_id)

    Enum.map(patterns, fn %RoutePattern{} = pattern ->
      %{
        route_pattern_id: pattern.route_pattern_id,
        name: pattern.route_pattern_name,
        direction_id: pattern.direction_id,
        headsign: pattern.headsign,
        occurrences:
          occurrences
          |> Map.get(pattern.id, [])
          |> Enum.map(&%{stop_id: &1.stop_id, position: &1.position})
      }
    end)
  end

  # -- normalization ----------------------------------------------------------

  defp inputs(
         scoped,
         route,
         selection,
         trip_rows,
         service_ids,
         stop_time_rows,
         frequency_rows,
         patterns
       ) do
    {services, unreadable} = services(scoped, service_ids, selection.interval)
    active_by_service = Map.new(services, &{&1.service_id, &1.active_dates})
    stop_times = Enum.map(stop_time_rows, &normalize_stop_time/1)
    frequencies = Enum.map(frequency_rows, &normalize_frequency/1)

    scope = %{
      organization_id: scoped.organization_id,
      gtfs_version_id: scoped.gtfs_version_id,
      route_id: route.id
    }

    %{
      scope: scope,
      route: route_summary(route),
      selection: selection,
      interval: selection.interval,
      services: Map.new(services, &{&1.service_id, &1}),
      service_ids: service_ids,
      trips: Enum.map(trip_rows, &normalize_trip(&1, active_by_service)),
      stop_times: stop_times,
      frequencies: frequencies,
      patterns: patterns,
      unreadable_service_ids: unreadable,
      totals: %{
        trips: length(trip_rows),
        stop_times: length(stop_times),
        frequencies: length(frequencies)
      },
      completeness: if(unreadable == [], do: :complete, else: :incomplete),
      feed_digest:
        digest(%{
          scope: scope,
          route: route.route_id,
          selection: selection,
          services: services,
          unreadable: unreadable,
          trips: Enum.map(trip_rows, &trip_digest_row/1),
          stop_times: stop_times,
          frequencies: frequencies,
          patterns: patterns
        })
    }
  end

  defp route_summary(%Route{} = route) do
    %{
      id: route.id,
      route_id: route.route_id,
      state: if(route.active, do: :active, else: :inactive),
      agency_id: route.agency_id
    }
  end

  defp normalize_trip(%Trip{} = trip, active_by_service) do
    %{
      trip_id: trip.trip_id,
      service_id: trip.service_id,
      direction_id: trip.direction_id,
      headsign: trip.trip_headsign,
      short_name: trip.trip_short_name,
      pattern_id: trip.route_pattern_id,
      service_dates: Map.get(active_by_service, trip.service_id, [])
    }
  end

  defp trip_digest_row(%Trip{} = trip) do
    {trip.trip_id, trip.service_id, trip.direction_id, trip.route_pattern_id}
  end

  defp normalize_stop_time(%StopTime{} = row) do
    %{
      trip_id: row.trip_id,
      stop_id: row.stop_id,
      stop_sequence: row.stop_sequence,
      arrival_time: row.arrival_time,
      departure_time: row.departure_time,
      arrival_secs: clock(row.arrival_time),
      departure_secs: clock(row.departure_time),
      timepoint: row.timepoint,
      pickup_type: row.pickup_type,
      drop_off_type: row.drop_off_type
    }
  end

  # Arrival and departure are parsed independently: an unreadable arrival stays
  # unknown rather than borrowing the departure, and both keep their service-day
  # seconds past 24:00.
  defp clock(value) do
    case GtfsTime.parse(value) do
      {:ok, seconds} -> seconds
      {:error, :invalid_time} -> nil
    end
  end

  defp normalize_frequency(%Frequency{} = row) do
    %{
      trip_id: row.trip_id,
      start_secs: clock(row.start_time),
      end_secs: clock(row.end_time),
      headway_secs: row.headway_secs,
      exact_times: if(row.exact_times == 1, do: 1, else: 0)
    }
  end

  # The weekly row and every exception of each scoped service are read whole, and
  # the effective dates come from the shared date evaluator. An unreadable
  # retained weekly range or a contradictory exception cannot be computed, so the
  # service is disclosed as unreadable and the answer is incomplete rather than
  # reporting no service.
  defp services(scoped, service_ids, {first, last}) do
    Enum.reduce(service_ids, {[], []}, fn service_id, {services, unreadable} ->
      case service_dates(scoped, service_id, first, last) do
        {:ok, service} -> {services ++ [service], unreadable}
        :unreadable -> {services, unreadable ++ [service_id]}
      end
    end)
    |> case do
      {services, unreadable} -> {Enum.sort_by(services, & &1.service_id), Enum.sort(unreadable)}
    end
  end

  defp service_dates(scoped, service_id, first, last) do
    calendar =
      Repo.one(
        from(c in Calendar,
          where:
            c.organization_id == ^scoped.organization_id and
              c.gtfs_version_id == ^scoped.gtfs_version_id and c.service_id == ^service_id
        )
      )

    exceptions =
      from(d in CalendarDate,
        where:
          d.organization_id == ^scoped.organization_id and
            d.gtfs_version_id == ^scoped.gtfs_version_id and d.service_id == ^service_id,
        order_by: [asc: d.date, asc: d.id]
      )
      |> Repo.all()

    try do
      {:ok,
       %{
         service_id: service_id,
         weekly: weekly_row(calendar),
         exceptions: Enum.map(exceptions, &%{date: &1.date, exception_type: exception_type(&1)}),
         active_dates: ServiceDates.active_dates_between(calendar, exceptions, first, last)
       }}
    rescue
      ArgumentError -> :unreadable
    end
  end

  defp weekly_row(nil), do: nil

  defp weekly_row(%Calendar{} = calendar) do
    %{
      monday: calendar.monday,
      tuesday: calendar.tuesday,
      wednesday: calendar.wednesday,
      thursday: calendar.thursday,
      friday: calendar.friday,
      saturday: calendar.saturday,
      sunday: calendar.sunday,
      start_date: calendar.start_date,
      end_date: calendar.end_date
    }
  end

  defp exception_type(%CalendarDate{exception_type: 2}), do: 2
  defp exception_type(%CalendarDate{}), do: 1

  # -- digest ----------------------------------------------------------------

  # The digest identifies the exact content this answer was computed from, not a
  # chronological revision: it covers the normalized rows the snapshot returned
  # and the server-owned scope and selection.
  defp digest(value) do
    value
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end
end
