defmodule GtfsPlanner.Gtfs.ReleaseComparison.Compare do
  @moduledoc """
  Assembles the deterministic, truthful difference result of two projected
  artifacts over one inclusive service window.

  `run/3` composes the three prepared pure entries and adds no semantics of its
  own: it evaluates each artifact independently through
  `GtfsPlanner.Gtfs.ReleaseComparison.Service.evaluate/3`, resolves
  correspondence through
  `GtfsPlanner.Gtfs.ReleaseComparison.Matching.match/2` and `match_trips/3`, and
  reports only what those two prove. It reads no file, calls no repository, takes
  no claim and repairs no reference.

  ## What a comparison may conclude

  Counts are compared per route, direction and date, and only when the route's
  identity is proven by the entity correspondence and both sides state their
  counts completely. Every other case is disclosed with the reason it could not
  be measured:

    * `:unmapped_route` - the route on this side has no proven correspondence,
      so a left group and a right group are never assumed to be the same service.
    * `:one_sided_unit` - one artifact states service on this route and date and
      the other states none. Absence of a group is not evidence of no service, so
      the row stays inspectable and its delta stays `nil`.
    * `:incomplete_counts` - at least one side retained a frequency window or
      rejected a template, so the group reports the departures it can count
      rather than the whole service.
    * `:left_evaluation_incomplete` / `:right_evaluation_incomplete` - one side
      itself has unknowns, no groups, or an incomplete count or span.
    * `:unknown_timezone` / `:timezone_mismatch` - timing is service-day seconds,
      so two trips may only be compared for aligned timing when both routes
      resolve to the same known timezone.
    * `:stop_meaning_changed`, `:stop_ambiguous`, `:stop_unresolved` - a pattern
      whose stops moved, cannot be told apart, or have no proven correspondence
      cannot be paired by pattern, so only its route/date counts are compared.

  A renamed identifier alone is never a loss. Two artifacts running the same
  service under different route or trip identifiers have equal counts, so the only
  difference they report is identifier churn in `:structural_changes`.

  ## Totals

  `totals` carries `exact_count_delta` and `scheduled_count_delta`, both `nil`
  with a sorted `reasons` list whenever any unit in the window is unmeasured. A
  total is never computed across an unknown route or an incomplete
  representation: a delta that silently skipped an unmeasurable unit would be
  indistinguishable from real service loss.

  ## Completeness and exclusions

  `completeness` is `%{status: :complete | :incomplete, reasons: [...]}`. It is
  `:complete` only when every supported semantic dimension was evaluated: both
  evaluations complete, at least one service group, every unit measured, no
  unresolved entity correspondence and no stop whose correspondence changed
  meaning. A no-difference verdict is therefore only ever *complete* when the
  bytes actually described the whole service.

  `exclusions` always discloses the entities this comparison does not evaluate at
  all - fares, pathways and Flex - because the admitted members are the service
  allowlist and nothing here reconstructs them from the live version.

  ## Determinism

  Every list is sorted by its stable keys, and `:digest` is the SHA-256 of a
  normalized, digest-free copy of the result, so the same two projections over the
  same window always produce the same digest. References are the typed physical
  row references of the admitted bytes - a file and a row - never a path, a URL
  or a host handle.
  """

  alias GtfsPlanner.Gtfs.ReleaseComparison.Matching
  alias GtfsPlanner.Gtfs.ReleaseComparison.Service

  @typedoc "One inclusive service window, as step 1 validated it."
  @type window :: %{required(:from) => Date.t(), required(:to) => Date.t()}

  @typedoc """
  One route/direction/date comparison row.

  A row is present for every unit either artifact states, including the ones
  whose delta could not be proven, so suppressing a whole-system conclusion never
  hides a valid independent row.
  """
  @type group :: %{
          required(:route) => String.t() | nil,
          required(:route_ids) => map(),
          required(:direction_id) => 0 | 1 | nil,
          required(:date) => Date.t(),
          required(:route_mapped?) => boolean(),
          required(:comparable?) => boolean(),
          required(:reason) => atom() | nil,
          required(:left) => side() | nil,
          required(:right) => side() | nil,
          required(:delta) => delta(),
          required(:span_reason) => atom() | nil,
          required(:pattern_pairs) => [map()],
          required(:pattern_reason) => atom() | nil
        }

  @type side :: %{
          required(:route_id) => String.t(),
          required(:timezone) => String.t() | nil,
          required(:scheduled_count) => non_neg_integer(),
          required(:exact_count) => non_neg_integer(),
          required(:count_complete?) => boolean(),
          required(:span_complete?) => boolean(),
          required(:first_secs) => non_neg_integer() | nil,
          required(:last_secs) => non_neg_integer() | nil,
          required(:pattern_count) => non_neg_integer(),
          required(:pattern_reason) => atom() | nil,
          required(:source_refs) => [map()]
        }

  @type delta :: %{
          required(:scheduled_count) => integer() | nil,
          required(:exact_count) => integer() | nil,
          required(:first_secs) => integer() | nil,
          required(:last_secs) => integer() | nil
        }

  @type effective_change :: %{
          required(:kind) =>
            :added | :removed | :count_changed | :timing_changed | :frequency_changed,
          required(:route) => String.t() | nil,
          required(:route_ids) => map(),
          required(:direction_id) => 0 | 1 | nil,
          required(:date) => Date.t() | nil,
          required(:dates) => [Date.t()],
          required(:counts) => map(),
          required(:delta) => delta(),
          required(:timing) => [map()] | nil,
          required(:frequency_windows) => map(),
          required(:trips) => %{
            required(:left) => String.t() | nil,
            required(:right) => String.t() | nil
          },
          required(:reason) => atom() | nil,
          required(:source_refs) => map()
        }

  @doc """
  Compares two projections over one inclusive window.

  Returns `{:error, :unsupported_size}` when either artifact is too large to
  evaluate, and raises `ArgumentError` for a window that ends before it starts,
  which step 1 validates before any artifact is selected.
  """
  @spec run(map(), map(), window()) :: {:ok, map()} | {:error, :unsupported_size}
  def run(left_projection, right_projection, %{from: from, to: to})
      when is_map(left_projection) and is_map(right_projection) do
    matches = Matching.match(left_projection, right_projection)

    with {:ok, left} <- Service.evaluate(left_projection, from, to),
         {:ok, right} <- Service.evaluate(right_projection, from, to) do
      {:ok,
       assemble(
         left_projection,
         right_projection,
         %{from: from, to: to},
         matches,
         left,
         right
       )}
    end
  end

  @doc """
  The route pairs this result actually proved, in a stable order.

  A pair is the pair of route identifiers one unit was keyed by: both sides
  when correspondence was proven, and the single side that exists otherwise.
  The `:key` is the opaque identity a caller narrows by; `:label` is what a
  person reads. An unmapped route keeps its own identity here, so it is
  offerable and never silently merged with an unrelated route.
  """
  @spec route_pairs(map()) :: [map()]
  def route_pairs(%{groups: groups}) do
    groups
    |> Enum.map(&{&1.route_ids, pair_key(&1.route_ids)})
    |> Enum.uniq_by(&elem(&1, 1))
    |> Enum.sort_by(&elem(&1, 1))
    |> Enum.map(fn {route_ids, key} ->
      %{key: key, left: route_ids.left, right: route_ids.right, label: pair_label(route_ids)}
    end)
  end

  defp pair_key(%{left: left, right: right}),
    do: "#{left || "?"}/#{right || "?"}"

  defp pair_label(%{left: left, right: right}) do
    cond do
      is_binary(left) and is_binary(right) -> "#{left} → #{right}"
      is_binary(left) -> "#{left} (earlier file only)"
      is_binary(right) -> "#{right} (candidate file only)"
      true -> "Unnamed route"
    end
  end

  @doc """
  Narrows a finished result to an explicit subset of its own route pairs and
  service dates.

  The selection is validated against the result it narrows: a route-pair key
  that names no unit, a date outside the compared window, or an empty subset is
  `{:error, :invalid_scope}`. Nothing is invented, and a narrowed result is
  still a complete `run/3` result: its counts, totals and completeness are
  recomputed for the scope rather than copied from the full comparison, and its
  `:digest` covers the narrowed body, so two different scopes can never share
  one identity.

  Every omitted route/date group is disclosed in `:exclusions`, so a narrowed
  result can never read as though the whole comparison had been shown.
  `:unknowns` and `:unresolved` are *not* narrowed: an unknown reason is
  evidence in its own right, and hiding one behind a narrower view would turn
  disclosed uncertainty into apparent certainty. They travel through unchanged,
  and the scope is recorded in `:scope` so a later consumer can tell a narrowed
  result from the full one.
  """
  @spec narrow(map(), map()) :: {:ok, map()} | {:error, :invalid_scope}
  def narrow(result, %{route_pair_keys: keys, dates: dates})
      when is_map(result) and is_list(keys) and is_list(dates) do
    available = MapSet.new(Enum.map(route_pairs(result), & &1.key))
    window = Date.range(result.window.from, result.window.to) |> Enum.to_list()

    if keys != [] and dates != [] and Enum.all?(keys, &MapSet.member?(available, &1)) and
         Enum.all?(dates, &(&1 in window)) do
      {:ok, scope_result(result, keys, dates)}
    else
      {:error, :invalid_scope}
    end
  end

  def narrow(_result, _selection), do: {:error, :invalid_scope}

  defp scope_result(result, keys, dates) do
    selected = MapSet.new(keys)
    in_scope = MapSet.new(dates)
    units = Enum.filter(result.groups, &unit_in_scope?(&1, selected, in_scope))
    kept_route_ids = route_ids_of(units)

    omitted =
      Enum.reject(result.groups, &unit_in_scope?(&1, selected, in_scope))

    narrowed =
      result
      |> Map.merge(%{
        groups: units,
        effective_changes:
          Enum.filter(result.effective_changes, &change_in_scope?(&1, selected, in_scope)),
        structural_changes:
          Enum.filter(result.structural_changes, &structural_in_scope?(&1, kept_route_ids)),
        totals: scoped_totals(units, result.totals),
        completeness: scoped_completeness(units, result.completeness),
        exclusions: result.exclusions ++ omitted_units(omitted) ++ [non_narrowed_disclosure()],
        scope: %{route_pair_keys: Enum.sort(keys), dates: Enum.sort(dates)}
      })

    Map.put(narrowed, :digest, digest(narrowed))
  end

  defp unit_in_scope?(unit, selected, in_scope),
    do: pair_key(unit.route_ids) in selected and unit.date in in_scope

  defp change_in_scope?(%{dates: dates} = change, selected, in_scope) do
    case change.route_ids do
      nil ->
        false

      route_ids ->
        pair_key(route_ids) in selected and dates != [] and Enum.any?(dates, &(&1 in in_scope))
    end
  end

  # Only a route's own change is attributable to a selected route pair. Stop,
  # trip and agency changes carry no route identity in this result, so they
  # stay in the narrowed result and the disclosure below says so.
  defp structural_in_scope?(change, kept_route_ids),
    do: change.entity == :route and change.id in kept_route_ids

  defp route_ids_of(units) do
    Enum.flat_map(units, fn unit ->
      [unit.route_ids.left, unit.route_ids.right]
    end)
    |> Enum.reject(&is_nil/1)
    |> MapSet.new()
  end

  defp omitted_units(omitted) do
    omitted
    |> Enum.sort_by(&{pair_key(&1.route_ids), Date.to_iso8601(&1.date), &1.direction_id || -1})
    |> Enum.map(fn unit ->
      %{
        entity: :route_date_unit,
        reason: :narrowed_out_of_scope,
        detail:
          "#{pair_label(unit.route_ids)} on #{Date.to_iso8601(unit.date)}" <>
            " was left out of the selected scope",
        left_id: unit.route_ids.left,
        right_id: unit.route_ids.right,
        date: unit.date
      }
    end)
  end

  defp non_narrowed_disclosure() do
    %{
      entity: :unknowns,
      reason: :not_narrowed_by_scope,
      detail:
        "Unknown rows and unresolved entity matches are not narrowed by a route or date scope"
    }
  end

  # An evaluation that was incomplete on either side stays a reason: narrowing
  # the units does not make an incomplete evaluation complete.
  defp scoped_totals(units, previous) do
    reasons =
      (Enum.map(units, & &1.reason) ++ evaluation_reasons(previous.reasons))
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> Enum.sort()

    base = %{
      reasons: reasons,
      measured_units: Enum.count(units, & &1.comparable?),
      total_units: length(units)
    }

    if reasons == [] do
      Map.merge(base, %{
        exact_count_delta:
          counted(units, :right, :exact_count) - counted(units, :left, :exact_count),
        scheduled_count_delta:
          counted(units, :right, :scheduled_count) - counted(units, :left, :scheduled_count)
      })
    else
      Map.merge(base, %{exact_count_delta: nil, scheduled_count_delta: nil})
    end
  end

  defp evaluation_reasons(reasons),
    do: Enum.filter(reasons, &String.ends_with?(to_string(&1), "_evaluation_incomplete"))

  defp scoped_completeness(units, previous) do
    reasons =
      (previous.reasons -- [:no_service_groups, :unmeasured_units]) ++
        completeness_reasons(units)

    reasons = reasons |> Enum.uniq() |> Enum.sort()

    %{status: if(reasons == [], do: :complete, else: :incomplete), reasons: reasons}
  end

  defp completeness_reasons(units) do
    []
    |> add_unless(units != [], :no_service_groups)
    |> add_unless(Enum.all?(units, & &1.comparable?), :unmeasured_units)
  end

  # -- assembly ---------------------------------------------------------------

  defp assemble(left_projection, right_projection, window, matches, left, right) do
    trips = Matching.match_trips(left, right, matches)
    routes = pairs(matches.routes)
    stops = stop_view(matches.stops)
    units = compare_units(left, right, routes, stops)

    differences =
      unit_changes(units) ++
        trip_changes(left_projection, right_projection, left, right, trips, routes, stops)

    structural =
      matches.structural_changes ++
        trips.structural_changes ++
        presence_changes(matches.routes, :route) ++
        identifier_changes(matches.routes) ++
        identifier_changes(matches.stops) ++
        identifier_changes(trips.pairs)

    result = %{
      artifacts: [left_projection.identity, right_projection.identity],
      window: window,
      groups: units,
      structural_changes: sort_changes(structural),
      effective_changes: Enum.sort_by(differences, &change_order/1),
      unresolved: sort_unresolved(matches.unresolved ++ trips.unresolved),
      unknowns: unknowns(left_projection, right_projection, left, right),
      totals: totals(units, left, right),
      completeness: completeness(units, left, right, matches, trips),
      exclusions: exclusions()
    }

    Map.put(result, :digest, digest(result))
  end

  # -- route/date units -------------------------------------------------------

  # A unit is one route, direction and date. The route is keyed by its canonical
  # identity - the left artifact's identifier - so a proven rename still lands in
  # one unit, while an unmapped route keeps its own identity and is never joined
  # to an unrelated route on the other side.
  defp compare_units(left, right, routes, stops) do
    left_units = unitize(Map.get(left, :groups, []), routes, stops)
    right_units = unitize(Map.get(right, :groups, []), routes, stops)

    left_units
    |> Map.keys()
    |> Kernel.++(Map.keys(right_units))
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.map(&diff_unit(&1, Map.get(left_units, &1), Map.get(right_units, &1), stops))
  end

  defp unitize(groups, routes, stops) do
    groups
    |> Enum.group_by(&{canonical(&1.route_id, routes), &1.route_id, &1.direction_id, &1.date})
    |> Enum.map(fn {{canonical_id, route_id, direction_id, date}, rows} ->
      side = side(rows, route_id, stops)

      {{canonical_id, direction_id, date},
       %{
         side: side,
         route_mapped?: not is_nil(canonical_id),
         patterns: patterns_of(rows, stops),
         pattern_reason: Enum.find_value(rows, &pattern_reason(&1.pattern, stops))
       }}
    end)
    |> Map.new()
  end

  defp side(rows, route_id, stops) do
    %{
      route_id: route_id,
      timezone: shared_timezone(rows),
      scheduled_count: sum(rows, :scheduled_count),
      exact_count: sum(rows, :exact_count),
      count_complete?: Enum.all?(rows, & &1.count_complete?),
      span_complete?: Enum.all?(rows, & &1.span_complete?),
      first_secs: lowest(rows, :first_secs),
      last_secs: highest(rows, :last_secs),
      pattern_count: length(rows),
      pattern_reason: Enum.find_value(rows, &pattern_reason(&1.pattern, stops)),
      source_refs: sort_refs(Enum.flat_map(rows, & &1.source_refs))
    }
  end

  defp sum(rows, field), do: Enum.reduce(rows, 0, &(&2 + Map.fetch!(&1, field)))

  # The extremes exist only when every contributing group states them, so a
  # suppressed span is never read as a zero-length one.
  defp lowest(rows, field), do: extreme(rows, field, &Enum.min/1)

  defp highest(rows, field), do: extreme(rows, field, &Enum.max/1)

  defp extreme(rows, field, reducer) do
    values = rows |> Enum.map(&Map.fetch!(&1, field)) |> Enum.reject(&is_nil/1)

    if length(values) == length(rows), do: reducer.(values), else: nil
  end

  # Two sides may only be compared for aligned timing when they agree on one
  # known timezone. A disagreement or an absent timezone is `nil`, never a
  # default that would make two local clocks look like one.
  defp shared_timezone(rows) do
    case rows |> Enum.map(& &1.timezone) |> Enum.uniq() do
      [timezone] -> timezone
      _disagreeing -> nil
    end
  end

  defp patterns_of(rows, _stops), do: rows |> Enum.map(& &1.pattern) |> Enum.uniq()

  defp diff_unit({canonical_id, direction_id, date}, left, right, _stops) do
    {comparable?, reason} = unit_reason(canonical_id, left, right)

    %{
      route: canonical_id,
      route_ids: route_ids(left, right),
      direction_id: direction_id,
      date: date,
      route_mapped?: not is_nil(canonical_id),
      comparable?: comparable?,
      reason: reason,
      left: left && left.side,
      right: right && right.side,
      delta: unit_delta(left, right, reason),
      span_reason: span_reason(left, right),
      pattern_pairs: pattern_pairs(left, right),
      pattern_reason: pattern_reason_of(left, right)
    }
  end

  defp unit_reason(_canonical_id, nil, nil), do: {false, :unmapped_route}
  defp unit_reason(nil, _left, _right), do: {false, :unmapped_route}
  defp unit_reason(_canonical_id, nil, _right), do: {false, :one_sided_unit}
  defp unit_reason(_canonical_id, _left, nil), do: {false, :one_sided_unit}

  defp unit_reason(_canonical_id, %{side: %{count_complete?: true}}, %{
         side: %{count_complete?: true}
       }),
       do: {true, nil}

  defp unit_reason(_canonical_id, _left, _right), do: {false, :incomplete_counts}

  # Counts are diffed only where they were proven comparable. The span is a
  # separate conclusion with its own guard: two service-day spans describe the
  # same ride only when both timezones are known and identical and neither side's
  # stop correspondence changed meaning.
  defp unit_delta(left, right, nil) do
    {first_secs, last_secs} = span_delta(left, right)

    %{
      scheduled_count: right.side.scheduled_count - left.side.scheduled_count,
      exact_count: right.side.exact_count - left.side.exact_count,
      first_secs: first_secs,
      last_secs: last_secs
    }
  end

  defp unit_delta(_left, _right, _reason), do: empty_delta()

  defp span_delta(left, right) do
    case span_reason(left, right) do
      nil ->
        {difference_of(left.side.first_secs, right.side.first_secs),
         difference_of(left.side.last_secs, right.side.last_secs)}

      _reason ->
        {nil, nil}
    end
  end

  defp span_reason(%{side: %{timezone: nil}}, _right), do: :unknown_timezone
  defp span_reason(_left, %{side: %{timezone: nil}}), do: :unknown_timezone

  defp span_reason(%{side: %{timezone: left}}, %{side: %{timezone: right}}) when left != right,
    do: :timezone_mismatch

  defp span_reason(%{pattern_reason: reason}, _right) when not is_nil(reason), do: reason
  defp span_reason(_left, %{pattern_reason: reason}) when not is_nil(reason), do: reason
  defp span_reason(_left, _right), do: nil

  defp difference_of(left, right) when is_integer(left) and is_integer(right), do: right - left
  defp difference_of(_left, _right), do: nil

  defp route_ids(nil, nil), do: %{left: nil, right: nil}
  defp route_ids(nil, right), do: %{left: nil, right: right.side.route_id}
  defp route_ids(left, nil), do: %{left: left.side.route_id, right: nil}

  defp route_ids(left, right),
    do: %{left: left.side.route_id, right: right.side.route_id}

  # -- pattern correspondence -------------------------------------------------

  # Patterns are only paired when every stop on both sides resolves to a proven
  # correspondence that did not change meaning. A moved, ambiguous or unresolved
  # stop leaves the pattern unpaired and the reason disclosed; the route/date
  # counts above it stay compared regardless.
  defp pattern_pairs(left, right) do
    if is_nil(pattern_reason_of(left, right)) do
      patterns = %{left: keyed(left), right: keyed(right)}

      (Map.keys(patterns.left) ++ Map.keys(patterns.right))
      |> Enum.uniq()
      |> Enum.sort()
      |> Enum.map(fn key ->
        %{
          pattern: Map.get(patterns.left, key) || Map.get(patterns.right, key),
          left: Map.get(patterns.left, key),
          right: Map.get(patterns.right, key)
        }
      end)
    else
      []
    end
  end

  defp keyed(nil), do: %{}
  defp keyed(%{patterns: patterns}), do: Map.new(patterns, &{pattern_key(&1), &1})

  defp pattern_reason_of(left, right),
    do: Enum.find_value([left, right], &(&1 && &1.pattern_reason))

  defp pattern_reason(pattern, stops) do
    Enum.find_value(pattern, fn occurrence ->
      stop_id = occurrence.stop_id

      cond do
        MapSet.member?(stops.meaning_changed, stop_id) -> :stop_meaning_changed
        MapSet.member?(stops.ambiguous, stop_id) -> :stop_ambiguous
        is_nil(canonical(stop_id, stops.pairs)) -> :stop_unresolved
        true -> nil
      end
    end)
  end

  defp pattern_key(pattern), do: Enum.map_join(pattern, ";", &"#{&1.sequence}:#{&1.stop_id}")

  # -- trip differences -------------------------------------------------------

  # Timing and frequency differences are reported per proven trip pair, in
  # service-day seconds and separately from one another: a shifted departure is
  # not a changed template, and a changed template is not a shifted departure.
  defp trip_changes(left_projection, right_projection, left, right, trips, routes, stops) do
    index = %{
      left: index_by(Map.get(left, :evaluated_trips, [])),
      right: index_by(Map.get(right, :evaluated_trips, []))
    }

    projects = %{
      left: Map.get(left_projection, :routes, %{}),
      right: Map.get(right_projection, :routes, %{})
    }

    trips.pairs
    |> Enum.filter(&(&1.category in [:exact_id, :unique_exact]))
    |> Enum.flat_map(&trip_change(&1, index, projects, routes, stops))
    |> Enum.reject(&is_nil/1)
  end

  defp trip_change(pair, index, projects, routes, stops) do
    case {Map.fetch(index.left, pair.left_ref.id), Map.fetch(index.right, pair.right_ref.id)} do
      {{:ok, left_trip}, {:ok, right_trip}} ->
        List.wrap(timing_change(pair, left_trip, right_trip, projects, routes, stops)) ++
          List.wrap(frequency_change(pair, left_trip, right_trip, projects, routes, stops))

      _missing ->
        nil
    end
  end

  # The pattern is the trip pair's own ordering, so a same-identifier trip whose
  # stop correspondence changed meaning cannot report an aligned timing
  # difference: the two vectors are not describing the same ride any more.
  defp timing_change(pair, left_trip, right_trip, projects, routes, stops) do
    dates = common_dates(left_trip, right_trip)

    case occurrence_deltas(left_trip, right_trip, stops) do
      nil ->
        suppressed(
          pair,
          left_trip,
          right_trip,
          routes,
          dates,
          stop_reason_of_trip(left_trip, stops)
        )

      [] ->
        nil

      deltas ->
        case shared_timezone(left_trip, right_trip, projects) do
          {:ok, _timezone} ->
            new_change(
              pair,
              left_trip,
              right_trip,
              :timing_changed,
              routes,
              dates,
              %{
                scheduled_count: nil,
                exact_count: nil,
                first_secs: hd(deltas).delta_secs,
                last_secs: List.last(deltas).delta_secs
              },
              %{timing: Enum.map(deltas, &Map.put(&1, :date, nil))}
            )

          {:error, reason} ->
            suppressed(pair, left_trip, right_trip, routes, dates, reason)
        end
    end
  end

  # A difference that is real but not measurable is disclosed with its reason and
  # no delta, rather than dropped or reported as no difference at all.
  defp suppressed(pair, left_trip, right_trip, routes, dates, reason) do
    new_change(pair, left_trip, right_trip, :timing_changed, routes, dates, empty_delta(), %{
      timing: nil
    })
    |> Map.put(:reason, reason || :unknown_timezone)
  end

  defp occurrence_deltas(left_trip, right_trip, stops) do
    left = left_trip.time_vector
    right = right_trip.time_vector

    cond do
      # Nothing to align means nothing to suppress: identical vectors are not a
      # difference, however unreadable their pattern is.
      left == right ->
        []

      not is_nil(stop_reason_of_trip(left_trip, stops)) ->
        nil

      not is_nil(stop_reason_of_trip(right_trip, stops)) ->
        nil

      left == [] or length(left) != length(right) ->
        nil

      not Enum.all?(left ++ right, &readable_time?/1) ->
        nil

      left == right ->
        []

      true ->
        [left, right]
        |> Enum.zip()
        |> Enum.with_index()
        |> Enum.map(fn {times, index} -> occurrence_delta(times, index) end)
    end
  end

  defp occurrence_delta({{left_arrival, left_departure}, {right_arrival, right_departure}}, index) do
    %{
      index: index,
      left_secs: left_departure,
      right_secs: right_departure,
      delta_secs: right_departure - left_departure,
      left_arrival_secs: left_arrival,
      right_arrival_secs: right_arrival,
      arrival_delta_secs: right_arrival - left_arrival
    }
  end

  defp readable_time?({arrival, departure}), do: is_integer(arrival) and is_integer(departure)

  defp stop_reason_of_trip(trip, stops), do: pattern_reason(trip.pattern, stops)

  # Two trips may only be compared for aligned timing when both routes resolve to
  # the same known timezone. An unresolvable route is unknown, and two different
  # timezones are two local clocks rather than a difference in departure.
  defp shared_timezone(left_trip, right_trip, projects) do
    with {:ok, left} <- known_timezone(Map.get(projects.left, left_trip.route_id)),
         {:ok, right} <- known_timezone(Map.get(projects.right, right_trip.route_id)) do
      if left == right, do: {:ok, left}, else: {:error, :timezone_mismatch}
    end
  end

  defp known_timezone(%{timezone: timezone, timezone_known?: true}) when is_binary(timezone),
    do: {:ok, timezone}

  defp known_timezone(_route), do: {:error, :unknown_timezone}

  defp frequency_change(pair, left_trip, right_trip, _projects, routes, _stops) do
    left = windows_of(left_trip)
    right = windows_of(right_trip)

    if left == right do
      nil
    else
      new_change(
        pair,
        left_trip,
        right_trip,
        :frequency_changed,
        routes,
        common_dates(left_trip, right_trip),
        empty_delta(),
        %{frequency_windows: %{left: left, right: right}}
      )
    end
  end

  defp common_dates(left_trip, right_trip) do
    right = MapSet.new(right_trip.service_dates)
    left_trip.service_dates |> Enum.filter(&MapSet.member?(right, &1)) |> Enum.sort()
  end

  defp windows_of(trip) do
    trip.frequencies
    |> Enum.map(fn window ->
      {window.start_secs, window.end_secs, window.headway_secs, window.exact_times}
    end)
    |> Enum.sort()
  end

  defp new_change(pair, left_trip, right_trip, kind, routes, dates, delta, extras) do
    %{
      kind: kind,
      route: canonical(left_trip.route_id, routes),
      route_ids: %{left: left_trip.route_id, right: right_trip.route_id},
      direction_id: left_trip.direction_id,
      date: nil,
      dates: dates,
      counts: %{left: nil, right: nil},
      delta: delta,
      timing: nil,
      frequency_windows: %{left: [], right: []},
      trips: %{left: left_trip.trip_id, right: right_trip.trip_id},
      reason: nil,
      source_refs: %{
        left: [row_ref(pair.left_ref)],
        right: [row_ref(pair.right_ref)]
      }
    }
    |> Map.merge(extras)
  end

  defp row_ref(ref), do: %{file: ref.file, row: ref.row}

  # References are the physical rows of the admitted bytes, deduplicated and
  # ordered so the same comparison always sorts the same way.
  defp sort_refs(refs) do
    refs
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.sort_by(&{&1.file, &1.row})
  end

  # -- effective changes ------------------------------------------------------

  defp unit_changes(units) do
    units
    |> Enum.filter(&changed?/1)
    |> Enum.map(&unit_change/1)
  end

  # A unit with a proven mapping, both sides present and complete counts changes
  # when either count differs. A one-sided unit is reported as added or removed
  # with no delta, because absence of a group is not evidence of no service.
  defp changed?(%{reason: :one_sided_unit}), do: true

  # An unmapped route or an incompletely stated count is a limit on what could be
  # compared, not a difference: the row stays in `:groups` with its reason and
  # its two independent counts, and nothing is claimed about how they relate.
  defp changed?(%{reason: reason}) when reason in [:unmapped_route, :incomplete_counts],
    do: false

  defp changed?(%{left: nil}), do: false
  defp changed?(%{right: nil}), do: false

  defp changed?(%{left: left, right: right}),
    do: left.scheduled_count != right.scheduled_count or left.exact_count != right.exact_count

  defp unit_change(%{left: nil, right: right} = unit) do
    unit_effect(:added, unit, nil, right, %{left: nil, right: counts(right)}, unit.reason)
  end

  defp unit_change(%{left: left, right: nil} = unit) do
    unit_effect(:removed, unit, left, nil, %{left: counts(left), right: nil}, unit.reason)
  end

  defp unit_change(unit) do
    unit_effect(
      :count_changed,
      unit,
      unit.left,
      unit.right,
      %{left: counts(unit.left), right: counts(unit.right)},
      unit.reason
    )
  end

  defp unit_effect(kind, unit, left, right, counts, reason) do
    %{
      kind: kind,
      route: unit.route,
      route_ids: unit.route_ids,
      direction_id: unit.direction_id,
      date: unit.date,
      dates: [unit.date],
      counts: counts,
      delta: unit.delta,
      timing: nil,
      frequency_windows: %{left: [], right: []},
      trips: %{left: nil, right: nil},
      reason: reason,
      source_refs: refs(left, right)
    }
  end

  defp counts(side), do: %{scheduled_count: side.scheduled_count, exact_count: side.exact_count}

  defp empty_delta,
    do: %{scheduled_count: nil, exact_count: nil, first_secs: nil, last_secs: nil}

  defp refs(nil, nil), do: %{left: [], right: []}
  defp refs(nil, right), do: %{left: [], right: right.source_refs}
  defp refs(left, nil), do: %{left: left.source_refs, right: []}

  defp refs(left, right), do: %{left: left.source_refs, right: right.source_refs}

  # -- structural changes -----------------------------------------------------

  # A route that exists on one side only is disclosed structurally. It is not
  # service loss: the correspondence result already reports it as unresolved, and
  # only a proven mapping may join two sides' counts.
  defp presence_changes(correspondences, entity) do
    for %{category: :unmatched} = correspondence <- correspondences,
        ref = correspondence.left_ref || correspondence.right_ref,
        do: %{
          entity: entity,
          id: ref.id,
          change: if(is_nil(correspondence.right_ref), do: :removed, else: :added),
          left: correspondence.left_ref && correspondence.left_ref.id,
          right: correspondence.right_ref && correspondence.right_ref.id,
          left_ref: correspondence.left_ref,
          right_ref: correspondence.right_ref,
          meaning_changed: false
        }
  end

  # Identifier churn is a real structural difference and is disclosed as one. It
  # is never counted as a service difference, because the counts it produced are
  # compared separately.
  defp identifier_changes(correspondences) do
    for %{category: :unique_exact, entity: entity, left_ref: left, right_ref: right} <-
          correspondences do
      %{
        entity: entity,
        id: left.id,
        change: :identifier,
        left: left.id,
        right: right.id,
        left_ref: left,
        right_ref: right,
        meaning_changed: false
      }
    end
  end

  # -- totals -----------------------------------------------------------------

  defp totals(units, left, right) do
    case total_reasons(units, left, right) do
      [] ->
        %{
          exact_count_delta:
            counted(units, :right, :exact_count) - counted(units, :left, :exact_count),
          scheduled_count_delta:
            counted(units, :right, :scheduled_count) - counted(units, :left, :scheduled_count),
          reasons: [],
          measured_units: length(units),
          total_units: length(units)
        }

      reasons ->
        %{
          exact_count_delta: nil,
          scheduled_count_delta: nil,
          reasons: reasons,
          measured_units: Enum.count(units, & &1.comparable?),
          total_units: length(units)
        }
    end
  end

  defp total_reasons(units, left, right) do
    evaluations =
      for {evaluation, side} <- [{left, :left}, {right, :right}],
          not Map.get(evaluation, :complete?, false),
          do: :"#{side}_evaluation_incomplete"

    (Enum.map(units, & &1.reason) ++ evaluations)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp counted(units, side, field) do
    Enum.reduce(units, 0, fn unit, total ->
      case Map.get(unit, side) do
        nil -> total
        value -> total + Map.fetch!(value, field)
      end
    end)
  end

  # -- completeness -----------------------------------------------------------

  # Every supported dimension must have been evaluated before a no-difference
  # verdict is called complete. The unsupported dimensions are disclosed in
  # `:exclusions` instead, because they are not this comparison's to evaluate.
  defp completeness(units, left, right, matches, trips) do
    reasons =
      []
      |> add_unless(Map.get(left, :complete?, false), :left_evaluation_incomplete)
      |> add_unless(Map.get(right, :complete?, false), :right_evaluation_incomplete)
      |> add_unless(units != [], :no_service_groups)
      |> add_unless(Enum.all?(units, & &1.comparable?), :unmeasured_units)
      |> add_unless(
        coverage_resolved?(matches.unresolved ++ trips.unresolved),
        :unresolved_entity_matches
      )
      |> add_unless(Enum.all?(matches.stops, &(not &1.meaning_changed)), :stop_meaning_changed)
      |> Enum.uniq()
      |> Enum.sort()

    %{status: if(reasons == [], do: :complete, else: :incomplete), reasons: reasons}
  end

  # An unresolved correspondence whose evidence was simply absent is a disclosed
  # difference, not missing coverage: the comparison found nothing and can say so.
  # Every other reason - an absent required field, a duplicated signature, an
  # unproven dependency - is a limit on what could be concluded, so it keeps the
  # result incomplete.
  defp coverage_resolved?(entries), do: Enum.all?(entries, &(&1.reason == :no_candidate))

  defp add_unless(reasons, true, _reason), do: reasons
  defp add_unless(reasons, false, reason), do: reasons ++ [reason]

  # -- unknowns ---------------------------------------------------------------

  # Each artifact's own disclosures travel through unchanged except for the side
  # they came from, so a reader can never take one artifact's unknown as the
  # other's.
  defp unknowns(left_projection, right_projection, left, right) do
    [left_projection, right_projection]
    |> Enum.with_index()
    |> Enum.flat_map(fn {projection, index} ->
      Enum.map(Map.get(projection, :unknowns, []), &projection_unknown(&1, index))
    end)
    |> Kernel.++(
      [left, right]
      |> Enum.with_index()
      |> Enum.flat_map(fn {evaluation, index} ->
        Enum.map(Map.get(evaluation, :unknowns, []), &evaluation_unknown(&1, index))
      end)
    )
    |> Enum.sort_by(&{&1.side, &1.layer, to_string(&1.reason), &1.entity_id || ""})
  end

  defp projection_unknown(unknown, index) do
    %{
      side: side(index),
      layer: :projection,
      entity: nil,
      entity_id: unknown.entity_id,
      field: unknown.field,
      reason: unknown.reason,
      detail: "#{unknown.field} could not be read from the selected bytes",
      source: %{file: unknown.file, row: unknown.row}
    }
  end

  defp evaluation_unknown(unknown, index) do
    %{
      side: side(index),
      layer: :evaluation,
      entity: unknown.entity,
      entity_id: unknown.entity_id,
      field: nil,
      reason: unknown.reason,
      detail: unknown.detail,
      source: Map.get(unknown, :source)
    }
  end

  defp side(0), do: :left
  defp side(_index), do: :right

  # -- exclusions -------------------------------------------------------------

  # These entities are outside the admitted member allowlist. Nothing here
  # reconstructs them, so the omission is disclosed rather than implied by an
  # absent list.
  defp exclusions do
    [
      exclusion(
        :fare,
        "fares.txt and fare_products.txt are not read, so fare changes are not compared"
      ),
      exclusion(
        :pathway,
        "pathways.txt and levels.txt are not read, so accessibility changes are not compared"
      ),
      exclusion(
        :flex,
        "flexible service locations stay disclosed as unevaluable stop references rather than compared"
      )
    ]
  end

  defp exclusion(entity, detail) do
    %{entity: entity, reason: :unsupported_table, detail: detail}
  end

  # -- stop view --------------------------------------------------------------

  # A stop whose correspondence changed meaning, or whose signature is shared by
  # several entities, cannot carry an aligned pattern comparison. The sets hold
  # the left artifact's identifiers plus the right ones, and `canonical/2` alone
  # keeps an unpaired stop out of every pattern.
  defp stop_view(correspondences) do
    meaning_changed =
      for %{category: category} = correspondence <- correspondences,
          category in [:exact_id, :unique_exact],
          correspondence.meaning_changed,
          ref <- sides(correspondence),
          do: ref.id

    ambiguous =
      for %{category: :ambiguous, left_ref: left, candidates: candidates} <- correspondences,
          ref <- [left | candidates],
          do: ref.id

    %{
      pairs: pairs(correspondences),
      meaning_changed: MapSet.new(meaning_changed),
      ambiguous: MapSet.new(ambiguous)
    }
  end

  defp sides(%{left_ref: left, right_ref: right}),
    do: Enum.reject([left, right], &is_nil/1)

  # -- pairs ------------------------------------------------------------------

  defp pairs(correspondences) do
    forward =
      for %{category: category, left_ref: %{id: id}, right_ref: %{id: right_id}} <-
            correspondences,
          category in [:exact_id, :unique_exact],
          into: %{},
          do: {id, right_id}

    %{forward: forward, reverse: Map.new(forward, fn {id, right_id} -> {right_id, id} end)}
  end

  # The canonical identity is always the left artifact's identifier, so both
  # sides of a proven pair land on one key and an unproven reference has none.
  defp canonical(id, %{forward: forward, reverse: reverse}) do
    cond do
      is_map_key(forward, id) -> id
      is_map_key(reverse, id) -> Map.fetch!(reverse, id)
      true -> nil
    end
  end

  defp index_by(trips), do: Map.new(trips, &{&1.trip_id, &1})

  # -- ordering ---------------------------------------------------------------

  defp change_order(change) do
    {
      to_string(change.kind),
      change.route || "",
      date_order(change.date),
      direction_order(change.direction_id),
      timing_order(change.timing),
      ref_order(change.source_refs)
    }
  end

  defp date_order(nil), do: ""
  defp date_order(%Date{} = date), do: Date.to_iso8601(date)

  defp direction_order(nil), do: -1
  defp direction_order(direction_id), do: direction_id

  defp timing_order(nil), do: ""
  defp timing_order(deltas), do: deltas |> hd() |> Map.fetch!(:index) |> to_string()

  defp ref_order(%{left: [first | _]}), do: first.row
  defp ref_order(_refs), do: 0

  defp sort_changes(changes), do: Enum.sort_by(changes, &{&1.entity, &1.id, &1.change})

  defp sort_unresolved(entries) do
    Enum.sort_by(entries, fn entry ->
      {entry.entity, ref_id(entry.left_ref), ref_id(entry.right_ref), to_string(entry.reason)}
    end)
  end

  defp ref_id(nil), do: ""
  defp ref_id(ref), do: ref.id

  # -- digest -----------------------------------------------------------------

  # The digest covers the whole result except itself, so the same two projections
  # over the same window always hash to the same value while any difference in
  # counts, references, reasons, totals, completeness or exclusions changes it.
  defp digest(result) do
    result
    |> Map.delete(:digest)
    |> normalize()
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp normalize(%Date{} = value), do: {:date, Date.to_iso8601(value)}
  defp normalize(%DateTime{} = value), do: {:datetime, DateTime.to_iso8601(value)}
  defp normalize(%Decimal{} = value), do: {:decimal, Decimal.to_string(value, :normal)}
  defp normalize(%_struct{} = value), do: normalize(Map.from_struct(value))

  defp normalize(value) when is_map(value) do
    entries =
      value
      |> Enum.map(fn {key, entry} -> {normalize(key), normalize(entry)} end)
      |> Enum.sort()

    {:map, entries}
  end

  defp normalize(value) when is_list(value), do: {:list, Enum.map(value, &normalize/1)}

  defp normalize(value) when is_atom(value) and not is_boolean(value) and not is_nil(value),
    do: {:atom, value}

  defp normalize(value), do: value
end
