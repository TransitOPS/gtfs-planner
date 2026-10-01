defmodule GtfsPlanner.Gtfs.ReleaseComparison.Matching do
  @moduledoc """
  Resolves exact correspondence between two projected release-comparison
  artifacts without ever guessing.

  `match/2` takes the two `GtfsPlanner.Gtfs.ReleaseComparison.Projection`
  results and returns the categorical correspondence of their agencies, routes
  and stops, the structural changes between matched pairs, and everything that
  stayed unresolved. `match_trips/3` takes the two step 5 evaluations plus this
  result and resolves trips.

  Correspondence is always one of four categories, never a probability:

    * `:exact_id` - the same identifier exists on both sides. The correspondence
      stays categorical even when the entity changed meaning, which is what
      `meaning_changed` records. A reused identifier never becomes a guess: it
      keeps `:exact_id` and discloses exactly which fields changed.
    * `:unique_exact` - a different identifier whose signature is unique on both
      sides. That is identifier churn, proven by exact equality of the typed
      fields the rule names and nothing else.
    * `:ambiguous` - the signature matches more than one entity on either side.
      Nothing is paired and every candidate reference is kept.
    * `:unmatched` - no correspondence: the entity exists on one side only, its
      evidence is absent, or a dependency it needs is unresolved.

  The rules are deliberately narrow, and absent evidence never creates a match.
  An agency needs a complete name, url and timezone. A route needs a resolved
  agency, a type and a nonblank name. A stop needs both coordinates, a name and a
  resolved parent. Coordinates compare by numeric equality, so `40.1` and
  `40.100` are one point, while a missing coordinate is never equal to anything.

  Stops are matched parents before children: a renamed stop whose parent is
  itself unresolved stays `:unmatched`, because a child is only as identifiable
  as the parent it belongs to. A parent resolved by an earlier pass lets its
  children match on a later one, so ordering never silently drops a real pair.

  A same-identifier stop or trip whose location type, parent, coordinates or
  ordered stop sequence changed keeps its `:exact_id` correspondence and is
  marked `meaning_changed: true`. That flag is what later steps use to suppress
  aligned timing claims instead of reporting a false unchanged result.

  `match_trips/3` takes the evaluated trip signatures as an explicit argument
  rather than reading dates itself, so it never re-derives native calendar
  semantics. A trip is only paired when its route identity is proven by the
  entity matches, and a trip may only match by signature when every stop in its
  pattern, its service-date set, its time vector and its frequencies are
  evaluable. See the `:evaluated_trip` type for the shape step 5 supplies.

  ## Unresolvable native references

  The native exporter writes each table's stored primary reference into the
  foreign columns, so a genuinely produced artifact's `routes.txt` names an
  agency UUID and its `trips.txt` names a route UUID. Those references are
  disclosed by the projection and are never repaired here. Such a route has no
  provable agency identity, so it can only ever be matched by identical
  identifier and its rename stays truthfully unresolved. The same holds for an
  occurrence whose stop cannot be resolved: it keeps a trip out of the
  renamed-trip rule instead of inventing a correspondence.

  All outputs are sorted, so a later result digest stays stable.
  """

  @type category :: :exact_id | :unique_exact | :ambiguous | :unmatched

  @type ref :: %{
          required(:id) => String.t(),
          required(:file) => String.t(),
          required(:row) => pos_integer()
        }

  @type correspondence :: %{
          required(:entity) => atom(),
          required(:category) => category(),
          required(:rule) => atom(),
          required(:reason) => atom(),
          required(:left_ref) => ref() | nil,
          required(:right_ref) => ref() | nil,
          required(:candidates) => [ref()],
          required(:meaning_changed) => boolean()
        }

  @type structural_change :: %{
          required(:entity) => atom(),
          required(:id) => String.t(),
          required(:change) => atom(),
          required(:left) => term(),
          required(:right) => term(),
          required(:left_ref) => ref(),
          required(:right_ref) => ref(),
          required(:meaning_changed) => boolean()
        }

  @type unresolved :: %{
          required(:entity) => atom(),
          required(:reason) => atom(),
          required(:left_ref) => ref() | nil,
          required(:right_ref) => ref() | nil,
          required(:candidates) => [ref()]
        }

  @type matches :: %{
          required(:agencies) => [correspondence()],
          required(:routes) => [correspondence()],
          required(:stops) => [correspondence()],
          required(:structural_changes) => [structural_change()],
          required(:unresolved) => [unresolved()]
        }

  @type pairs :: %{required(:forward) => map(), required(:reverse) => map()}

  @typedoc """
  One evaluated trip as step 5 supplies it to `match_trips/3`.

  A trip may only match by signature when every field is present and evaluable.
  A missing time, an unevaluated service or an unsupported frequency leaves the
  trip out of the renamed-trip rule rather than matching it on the fields that
  did parse.
  """
  @type evaluated_trip :: %{
          required(:trip_id) => String.t(),
          required(:route_id) => String.t(),
          required(:direction_id) => 0 | 1 | nil,
          required(:service_dates) => [Date.t()],
          required(:pattern) => [
            %{required(:stop_id) => String.t(), required(:sequence) => term()}
          ],
          required(:time_vector) => [{term(), term()}],
          required(:frequencies) => [map()]
        }

  @doc """
  Resolves agency, route and stop correspondence between two projections.
  """
  @spec match(map(), map()) :: matches()
  def match(
        %{agencies: left_agencies, routes: left_routes, stops: left_stops},
        %{agencies: right_agencies, routes: right_routes, stops: right_stops}
      ) do
    {agencies, agency_changes, agency_forward} =
      match_agencies(left_agencies, right_agencies)

    {routes, route_changes, _route_forward} =
      match_routes(left_routes, right_routes, pairs(agency_forward))

    {stops, stop_changes, _stop_pairs} = match_stops(left_stops, right_stops)

    correspondences = agencies ++ routes ++ stops

    %{
      agencies: sort_correspondences(agencies),
      routes: sort_correspondences(routes),
      stops: sort_correspondences(stops),
      structural_changes: sort_changes(agency_changes ++ route_changes ++ stop_changes),
      unresolved: sort_unresolved(unresolved_of(correspondences))
    }
  end

  @doc """
  Resolves trip correspondence between two step 5 evaluations.

  `entity_matches` is the `match/2` result. A trip is paired by identical
  identifier only when its route identity is proven - both sides naming the same
  route identifier, or each naming a route `match/2` paired. A same-identifier
  trip whose route identity is unproven stays unresolved rather than becoming a
  correspondence.
  """
  @spec match_trips(map(), map(), matches()) :: %{
          required(:pairs) => [correspondence()],
          required(:structural_changes) => [structural_change()],
          required(:unresolved) => [unresolved()]
        }
  def match_trips(left_evaluation, right_evaluation, entity_matches) do
    deps = %{
      routes: pairs_of(Map.get(entity_matches, :routes, [])),
      stops: pairs_of(Map.get(entity_matches, :stops, []))
    }

    {pairs, changes, _forward} =
      resolve(
        :trip,
        evaluated_index(left_evaluation),
        evaluated_index(right_evaluation),
        rules(&trip_signature/3, &trip_changes/4, &trip_reason/3, &route_identity?/4),
        deps
      )

    %{
      pairs: sort_correspondences(pairs),
      structural_changes: sort_changes(changes),
      unresolved: sort_unresolved(unresolved_of(pairs))
    }
  end

  # -- agencies ---------------------------------------------------------------

  defp match_agencies(left, right) do
    resolve(
      :agency,
      left,
      right,
      rules(&agency_signature/3, &agency_changes/4, &agency_reason/3, nil),
      %{}
    )
  end

  # A rename is proven only by a complete, identical identity triple. A blank
  # name or url and a missing timezone are absent evidence, not a signature.
  defp agency_signature(agency, _own, _deps) do
    if agency.name != "" and agency.url != "" and not is_nil(agency.timezone) do
      {:agency, agency.name, agency.url, agency.timezone}
    end
  end

  defp agency_reason(agency, _own, _deps) do
    if is_nil(agency_signature(agency, %{}, %{})), do: :incomplete_signature, else: :no_candidate
  end

  defp agency_changes(left, right, _own, _deps) do
    {changed, meaning_changed?} =
      compare(left, right, [name: :name, url: :url, timezone: :timezone], [:timezone])

    {changed, meaning_changed?}
  end

  # -- routes -----------------------------------------------------------------

  defp match_routes(left, right, agency_pairs) do
    resolve(
      :route,
      left,
      right,
      rules(&route_signature/3, &route_changes/4, &route_reason/3, nil),
      agency_pairs
    )
  end

  # A route is identified by its mapped agency, its type and its names. A route
  # whose agency reference does not resolve has no provable identity beyond its
  # own identifier, so it can never be matched as a rename.
  defp route_signature(route, _own, agency_pairs) do
    if resolved?(route.agency_id, agency_pairs) and nonblank_name?(route) do
      {:route, canonical(route.agency_id, agency_pairs), route.route_type, route.short_name,
       route.long_name}
    end
  end

  defp route_reason(route, _own, agency_pairs) do
    cond do
      not resolved?(route.agency_id, agency_pairs) -> :unresolved_agency
      is_nil(route_signature(route, %{}, agency_pairs)) -> :incomplete_signature
      true -> :no_candidate
    end
  end

  defp nonblank_name?(route), do: route.short_name != "" or route.long_name != ""

  defp route_changes(left, right, _own, _deps) do
    compare(
      left,
      right,
      [short_name: :short_name, long_name: :long_name, route_type: :route_type],
      [:route_type]
    )
  end

  # -- stops ------------------------------------------------------------------

  defp match_stops(left, right) do
    resolve(
      :stop,
      left,
      right,
      rules(&stop_signature/3, &stop_changes/4, &stop_reason/3, nil),
      %{}
    )
  end

  # A stop is identified by its exact coordinates, its location type, its name
  # and its parent. A missing coordinate or a blank name is absent evidence.
  defp stop_signature(stop, own, _deps) do
    with lat when not is_nil(lat) <- stop.lat,
         lon when not is_nil(lon) <- stop.lon,
         true <- stop.name != "",
         parent when not is_nil(parent) <- parent_identity(stop, own) do
      {:stop, decimal_key(lat), decimal_key(lon), stop.location_type, stop.name, parent}
    else
      _absent -> nil
    end
  end

  defp stop_reason(stop, own, _deps) do
    cond do
      stop.parent_station != "" and is_nil(parent_identity(stop, own)) -> :unresolved_parent
      is_nil(stop_signature(stop, own, %{})) -> :incomplete_signature
      true -> :no_candidate
    end
  end

  # The parent is resolved only when it has a proven correspondence, and it is
  # compared in the right artifact's identifier space on both sides so a renamed
  # parent does not make its children look unrelated.
  defp parent_identity(stop, own) do
    case stop.parent_station do
      "" -> :root
      parent when is_nil(parent) -> nil
      parent -> Map.get(own.forward, parent, nil) && {:parent, own.forward[parent]}
    end
  end

  defp stop_changes(left, right, own, _deps) do
    same_coordinates? = same_coordinates?(left, right)
    same_parent? = parent_identity(left, own) == parent_identity(right, own)

    changed =
      []
      |> add_change(:name, left.name, right.name, false)
      |> add_change(:location_type, left.location_type, right.location_type, true)
      |> add_change(
        :coordinates,
        {decimal_key(left.lat), decimal_key(left.lon)},
        {decimal_key(right.lat), decimal_key(right.lon)},
        not same_coordinates?
      )
      |> add_change(
        :parent_station,
        parent_identity(left, own),
        parent_identity(right, own),
        not same_parent?
      )

    meaning_changed? =
      Enum.any?(changed, fn {_change, _left, _right, meaning?} -> meaning? end)

    {changed, meaning_changed?}
  end

  # Coordinate equality is numeric: `40.100` and `40.1` are one point, and a
  # missing coordinate is never equal to a present one.
  defp same_coordinates?(left, right) do
    same_decimal?(left.lat, right.lat) and same_decimal?(left.lon, right.lon)
  end

  defp same_decimal?(nil, nil), do: true
  defp same_decimal?(left, right) when is_nil(left) or is_nil(right), do: false

  defp same_decimal?(left, right) do
    Decimal.equal?(left, right)
  end

  # The canonical textual form of a coordinate, so a signature compares equal
  # values rather than equal-looking strings.
  defp decimal_key(nil), do: nil
  defp decimal_key(decimal), do: decimal |> Decimal.normalize() |> Decimal.to_string(:normal)

  # -- trips ------------------------------------------------------------------

  defp evaluated_index(%{evaluated_trips: trips}) when is_list(trips), do: index_by_id(trips)
  defp evaluated_index(%{trips: trips}) when is_list(trips), do: index_by_id(trips)
  defp evaluated_index(_evaluation), do: %{}

  defp index_by_id(trips), do: Map.new(trips, &{&1.trip_id, &1})

  # A trip is identified by its route, direction, ordered resolved-stop pattern,
  # service-date set, time vector and frequency templates. Anything the
  # evaluation could not read leaves the trip out of the rename rule entirely.
  defp trip_signature(trip, _own, deps) do
    with route when not is_nil(route) <- canonical(trip.route_id, deps.routes),
         pattern when not is_nil(pattern) <- resolved_pattern(trip, deps.stops),
         true <- trip.service_dates != [],
         vector when not is_nil(vector) <- time_vector(trip),
         frequencies when not is_nil(frequencies) <- frequencies(trip) do
      {:trip, route, trip.direction_id, pattern, service_dates(trip), vector, frequencies}
    else
      _unevaluable -> nil
    end
  end

  defp trip_reason(trip, _own, deps) do
    cond do
      not resolved?(trip.route_id, deps.routes) -> :unresolved_route
      is_nil(trip_signature(trip, %{}, deps)) -> :incomplete_signature
      true -> :no_candidate
    end
  end

  # A route identity is proven when both sides name the same route identifier or
  # when each names a route `match/2` paired. Nothing else counts: a trip whose
  # route reference resolves to nothing has no identity to inherit.
  defp route_identity?(left_route, right_route, _own, deps) do
    left_route == right_route or resolved?(left_route, deps.routes) or
      resolved?(right_route, deps.routes)
  end

  # A same-identifier trip whose mapped route or ordered pattern changed keeps its
  # categorical correspondence and is marked as having changed meaning, which is
  # what suppresses an aligned timing claim later on. A time or frequency change
  # is a real service difference, not an identity difference, so it is disclosed
  # as a structural change without claiming the identity changed meaning.
  defp trip_changes(left, right, _own, deps) do
    same_route? = canonical(left.route_id, deps.routes) == canonical(right.route_id, deps.routes)
    same_pattern? = resolved_pattern(left, deps.stops) == resolved_pattern(right, deps.stops)

    changed =
      []
      |> add_change(:route_id, left.route_id, right.route_id, not same_route?)
      |> add_change(:direction_id, left.direction_id, right.direction_id, false)
      |> add_change(
        :stop_pattern,
        resolved_pattern(left, deps.stops),
        resolved_pattern(right, deps.stops),
        not same_pattern?
      )
      |> add_change(:service_dates, service_dates(left), service_dates(right), false)
      |> add_change(:time_vector, time_vector(left), time_vector(right), false)
      |> add_change(:frequencies, frequencies(left), frequencies(right), false)

    {changed, not (same_route? and same_pattern?)}
  end

  # The ordered pattern a trip is identified by: every stop resolved through the
  # proven stop correspondence and kept with its sequence, so a loop's repeated
  # stop stays a distinct position. An unresolved stop makes the pattern nil.
  defp resolved_pattern(trip, stops) do
    if Enum.any?(trip.pattern, &is_nil(canonical(&1.stop_id, stops))) do
      nil
    else
      Enum.map(trip.pattern, &{&1.sequence, canonical(&1.stop_id, stops)})
    end
  end

  # The trip's own time vector in service-day seconds. An unreadable time stays
  # `nil` rather than becoming midnight or a zero, so a partially readable trip
  # can never match a complete one.
  defp time_vector(trip) do
    if Enum.any?(trip.time_vector, fn {arrival, departure} ->
         is_nil(arrival) or is_nil(departure)
       end) do
      nil
    else
      Enum.map(trip.time_vector, fn {arrival, departure} -> {arrival, departure} end)
    end
  end

  defp service_dates(trip) do
    trip.service_dates |> Enum.sort(Date) |> Enum.map(&Date.to_iso8601/1)
  end

  defp frequencies(trip) do
    if Enum.any?(trip.frequencies, &unsupported_frequency?/1) do
      nil
    else
      trip.frequencies
      |> Enum.map(&{&1.start_secs, &1.end_secs, &1.headway_secs, &1.exact_times})
      |> Enum.sort()
    end
  end

  defp unsupported_frequency?(entry) do
    entry.exact_times not in [0, 1] or is_nil(entry.start_secs) or is_nil(entry.end_secs) or
      is_nil(entry.headway_secs)
  end

  # -- shared resolution ------------------------------------------------------

  # The per-entity rules travel as one map rather than as loose parameters: a
  # signature, a change detector, a residual-reason detector and an optional
  # same-identifier gate. Every one of them receives `(item, own, deps)`, where
  # `own` is the correspondence proven so far and `deps` is the already-proven
  # correspondence of the entity this one depends on.
  defp rules(signature, change, reason, precheck) do
    %{signature: signature, change: change, reason: reason, precheck: precheck}
  end

  defp resolve(entity, left_index, right_index, rules, deps) do
    {correspondences, changes, forward} =
      pair_same_ids(entity, left_index, right_index, rules, deps)

    own = pairs(forward)

    {renamed, renamed_forward} =
      signature_pass(entity, left_index, right_index, rules, own, deps, taken(correspondences))

    forward = Map.merge(forward, renamed_forward)
    all = correspondences ++ renamed

    residual =
      residual_correspondences(
        entity,
        left_index,
        right_index,
        rules,
        pairs(forward),
        deps,
        taken(all)
      )

    {all ++ residual, changes, forward}
  end

  # The identifiers already spoken for, so each is offered as a candidate once.
  defp taken(entries) do
    %{
      left: MapSet.new(Enum.map(entries, & &1.left_ref.id)),
      right: MapSet.new(Enum.map(entries, & &1.right_ref.id))
    }
  end

  # An identical identifier is categorical evidence even when the entity changed
  # meaning, so it is paired first and its changed fields are disclosed. The
  # changes are computed once every identifier pair is known, so a stop's
  # resolved parent is compared through the correspondence rather than through
  # two raw strings that happen to be equal.
  defp pair_same_ids(entity, left_index, right_index, rules, deps) do
    forward =
      left_index
      |> Map.keys()
      |> Enum.sort()
      |> Map.new(fn id -> {id, if(Map.has_key?(right_index, id), do: id)} end)
      |> Enum.reject(fn {_id, right_id} -> is_nil(right_id) end)
      |> Map.new()

    own = pairs(forward)
    precheck = rules.precheck

    Enum.reduce(Enum.sort(Map.keys(forward)), {[], [], forward}, fn id, acc ->
      {correspondences, changes, pairs_so_far} = acc
      left = Map.fetch!(left_index, id)
      right = Map.fetch!(right_index, Map.fetch!(pairs_so_far, id))

      if precheck && not precheck.(left.route_id, right.route_id, own, deps) do
        # The identifier is shared but its route identity is not proven, so the
        # pair is withheld and both trips fall through to the residual pass,
        # where the unproven route is disclosed as the reason.
        acc
      else
        {changed, meaning_changed?} = rules.change.(left, right, own, deps)

        {correspondences ++ [same_id(entity, left, right, meaning_changed?)],
         changes ++ entry_changes(entity, id, changed, meaning_changed?, left, right),
         pairs_so_far}
      end
    end)
  end

  defp same_id(entity, left, right, meaning_changed?) do
    %{
      entity: entity,
      category: :exact_id,
      rule: rule_for(entity, :exact_id),
      reason: :same_id,
      left_ref: ref(entity, left),
      right_ref: ref(entity, right),
      candidates: [],
      meaning_changed: meaning_changed?
    }
  end

  defp entry_changes(entity, id, changed, meaning_changed?, left, right) do
    Enum.map(changed, fn {change_name, left_value, right_value, _meaning?} ->
      change_struct(
        entity,
        id,
        change_name,
        left_value,
        right_value,
        meaning_changed?,
        ref(entity, left),
        ref(entity, right)
      )
    end)
  end

  # A signature that is unique on both sides is identifier churn, proven by
  # exact equality. The pass repeats while it still makes progress, so a child
  # whose parent matched in this pass can match in the next one. Already paired
  # identifiers are removed from the candidate set first: without that an entity
  # keeps re-matching itself and the pass never terminates.
  defp signature_pass(entity, left_index, right_index, rules, own, deps, taken) do
    left_groups = signatures(left_index, taken.left, :left, rules, own, deps)
    right_groups = signatures(right_index, taken.right, :right, rules, own, deps)

    case unique_pairs(left_groups, right_groups) do
      unique when map_size(unique) == 0 ->
        {[], %{}}

      unique ->
        correspondences =
          unique
          |> Enum.sort()
          |> Enum.map(fn {left_id, right_id} ->
            %{
              entity: entity,
              category: :unique_exact,
              rule: rule_for(entity, :unique_exact),
              reason: :unique_exact_signature,
              left_ref: ref(entity, Map.fetch!(left_index, left_id)),
              right_ref: ref(entity, Map.fetch!(right_index, right_id)),
              candidates: [],
              meaning_changed: false
            }
          end)

        # The proven pair joins `own`, so the next pass resolves a child's parent
        # through it, and each identifier is offered as a candidate once.
        own = pairs(Map.merge(own.forward, unique))

        {later, later_forward} =
          signature_pass(
            entity,
            left_index,
            right_index,
            rules,
            own,
            deps,
            take(correspondences, taken)
          )

        {correspondences ++ later, Map.merge(unique, later_forward)}
    end
  end

  defp take(entries, taken) do
    %{
      left: MapSet.union(taken.left, MapSet.new(Enum.map(entries, & &1.left_ref.id))),
      right: MapSet.union(taken.right, MapSet.new(Enum.map(entries, & &1.right_ref.id)))
    }
  end

  defp signatures(index, taken, _side, rules, own, deps) do
    index
    |> Map.keys()
    |> remaining(taken)
    |> Enum.flat_map(fn id ->
      case rules.signature.(Map.fetch!(index, id), own, deps) do
        nil -> []
        key -> [{key, id}]
      end
    end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
  end

  defp remaining(ids, taken), do: ids |> Enum.sort() |> Enum.reject(&MapSet.member?(taken, &1))

  # A signature pair is only a correspondence when it is unique on both sides:
  # one left and one right. Two left or two right is an ambiguous signature and
  # is disclosed by the residual pass with every candidate reference.
  defp unique_pairs(left_groups, right_groups) do
    for {key, [left_id]} <- left_groups,
        [right_id] <- [Map.get(right_groups, key)],
        into: %{},
        do: {left_id, right_id}
  end

  # Whatever is left is disclosed rather than dropped. A signature shared by more
  # than one entity on either side is ambiguous and keeps every candidate
  # reference; an entity whose own evidence is absent says why it stayed
  # unmatched, so a missing value never becomes a correspondence.
  defp residual_correspondences(entity, left_index, right_index, rules, own, deps, taken) do
    left_groups = signatures(left_index, taken.left, :left, rules, own, deps)
    right_groups = signatures(right_index, taken.right, :right, rules, own, deps)

    side(:left, entity, left_index, {right_index, right_groups}, rules, {own, deps, taken.left}) ++
      side(
        :right,
        entity,
        right_index,
        {left_index, left_groups},
        rules,
        {own, deps, taken.right}
      )
  end

  defp side(which, entity, index, {other_index, other_groups}, rules, {own, deps, taken}) do
    index
    |> Map.keys()
    |> remaining(taken)
    |> Enum.map(fn id ->
      item = Map.fetch!(index, id)
      own_ref = ref(entity, item)
      candidates = candidates_for(item, other_index, other_groups, rules, own, deps, entity)

      if candidates == [] do
        correspondence(
          entity,
          :unmatched,
          rules.reason.(item, own, deps),
          which,
          own_ref,
          nil,
          [],
          false
        )
      else
        # An ambiguous signature keeps `:ambiguous_signature` as its reason: the
        # evidence is present and duplicated, which is a different fact from
        # evidence that is absent or a dependency that is unresolved.
        correspondence(
          entity,
          :ambiguous,
          :ambiguous_signature,
          which,
          own_ref,
          nil,
          candidates,
          false
        )
      end
    end)
  end

  # Every entity on the other side that shares this item's signature: the
  # concrete evidence an ambiguous correspondence has to keep.
  defp candidates_for(item, other_index, other_groups, rules, own, deps, entity) do
    case rules.signature.(item, own, deps) do
      nil ->
        []

      key ->
        other_groups
        |> Map.get(key, [])
        |> Enum.sort()
        |> Enum.map(fn id -> ref(entity, Map.fetch!(other_index, id)) end)
    end
  end

  defp correspondence(entity, category, reason, which, own_ref, other_ref, candidates, meaning) do
    {left_ref, right_ref} =
      if which == :left, do: {own_ref, other_ref}, else: {other_ref, own_ref}

    %{
      entity: entity,
      category: category,
      rule: rule_for(entity, category),
      reason: reason,
      left_ref: left_ref,
      right_ref: right_ref,
      candidates: candidates,
      meaning_changed: meaning
    }
  end

  defp rule_for(:agency, _category), do: :agency_name_url_timezone
  defp rule_for(:route, _category), do: :mapped_agency_type_names
  defp rule_for(:stop, _category), do: :coordinates_type_name_parent
  defp rule_for(:trip, _category), do: :route_pattern_dates_times_frequencies

  defp compare(left, right, comparable, meaning_changed_fields) do
    changed =
      Enum.flat_map(comparable, fn {field, name} ->
        left_value = Map.fetch!(left, field)
        right_value = Map.fetch!(right, field)
        add_change([], name, left_value, right_value, name in meaning_changed_fields)
      end)

    {changed, Enum.any?(changed, &elem(&1, 3))}
  end

  defp add_change(changes, name, left_value, right_value, meaning?) do
    if left_value == right_value do
      changes
    else
      changes ++ [{name, left_value, right_value, meaning?}]
    end
  end

  defp change_struct(entity, id, change, left, right, meaning?, left_ref, right_ref) do
    %{
      entity: entity,
      id: id,
      change: change,
      left: left,
      right: right,
      left_ref: left_ref,
      right_ref: right_ref,
      meaning_changed: meaning?
    }
  end

  # The reference carries the entity's own identifier, which is the key the
  # projection indexed it by. It is taken from the entity, not from the map
  # body, because a route also names an agency and a stop also names a parent.
  defp ref(entity, %{source: source} = item) do
    %{id: entity_id(entity, item), file: source.file, row: source.row}
  end

  defp entity_id(:trip, %{trip_id: id}), do: id
  defp entity_id(:agency, %{agency_id: id}), do: id
  defp entity_id(:route, %{route_id: id}), do: id
  defp entity_id(:stop, %{stop_id: id}), do: id

  # -- pairs ------------------------------------------------------------------

  defp pairs_of(correspondences) do
    forward =
      for %{category: category, left_ref: %{id: id}, right_ref: %{id: right_id}} <-
            correspondences,
          category in [:exact_id, :unique_exact],
          into: %{},
          do: {id, right_id}

    %{forward: forward, reverse: reverse_of(forward)}
  end

  # The canonical identity of an identifier: the left artifact's identifier when
  # the pair is proven, otherwise `nil`. An identifier with no proven
  # correspondence has no canonical identity at all, which is what keeps an
  # unresolvable native foreign reference out of every signature.
  defp canonical(id, pairs) do
    cond do
      id == "" -> nil
      is_map_key(pairs.forward, id) -> id
      is_map_key(pairs.reverse, id) -> Map.fetch!(pairs.reverse, id)
      true -> nil
    end
  end

  defp resolved?(id, pairs), do: not is_nil(canonical(id, pairs))

  defp pairs(forward), do: %{forward: forward, reverse: reverse_of(forward)}

  defp reverse_of(forward) do
    for {left_id, right_id} <- forward, into: %{}, do: {right_id, left_id}
  end

  # -- ordering ---------------------------------------------------------------

  defp sort_correspondences(entries) do
    Enum.sort_by(entries, fn entry ->
      {ref_id(entry.left_ref), ref_id(entry.right_ref), to_string(entry.category)}
    end)
  end

  defp sort_changes(changes) do
    Enum.sort_by(changes, &{&1.entity, &1.id, &1.change})
  end

  defp sort_unresolved(entries) do
    Enum.sort_by(
      entries,
      &{&1.entity, ref_id(&1.left_ref), ref_id(&1.right_ref), to_string(&1.reason)}
    )
  end

  defp unresolved_of(correspondences) do
    for %{
          entity: entity,
          category: category,
          reason: reason,
          left_ref: left_ref,
          right_ref: right_ref,
          candidates: candidates
        } <- correspondences,
        category in [:ambiguous, :unmatched] do
      %{
        entity: entity,
        reason: reason,
        left_ref: left_ref,
        right_ref: right_ref,
        candidates: candidates
      }
    end
  end

  defp ref_id(nil), do: ""
  defp ref_id(ref), do: ref.id
end
