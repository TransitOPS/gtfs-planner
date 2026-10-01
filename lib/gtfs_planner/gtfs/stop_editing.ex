defmodule GtfsPlanner.Gtfs.StopEditing do
  @moduledoc """
  The commands the stop editor runs, each one an audited transaction (INV-2).

  Every write to a stop in this app goes through a function in this module, not
  through a changeset in a LiveView. That is what makes INV-2 checkable rather
  than aspirational: the audit entry and the mutation are written by the same
  closure, so there is no interleaving in which a stop changed and nobody wrote
  down who changed it.

  The shape follows `GtfsPlanner.Gtfs.Routes`, which is the established command
  module in this codebase and the one the stop editor's history view already
  reads. The four helpers below — authorize, lock, run, audit — are that module's
  helpers rather than a fresh set of ideas, deliberately: "why does a denied
  actor get `:forbidden` here and something else there" should not be a question
  this repo has to answer twice.

  ## Scoping

  `organization_id` and `gtfs_version_id` always come from the `%AuditContext{}`,
  never from the submitted attributes. A form that carried its own scope would be
  a form that could write into another organization's feed by changing a hidden
  field, so the attributes are cast through `Stop.editor_changeset/2` into a
  `%Stop{}` that already has the scope set on the struct.

  ## Stop IDs

  A stop ID is permanent. The feed, the rider information and every operator's
  downstream tooling are keyed on it, so `create_stop/2` never fills a gap and
  never renames an existing stop. When the editor types an ID, that ID is the ID
  and a duplicate is an error the editor sees. When the editor types none, the ID
  is the highest integer ID in the version plus one, skipping any number a garage
  of this organization already occupies: `StopNaming.next_stop_id/3` owns that
  rule and this module only feeds it.
  """

  import Ecto.Query

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Accounts.UserOrgMembership
  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.Alignments
  alias GtfsPlanner.Gtfs.AlignmentSegment
  alias GtfsPlanner.Gtfs.AuditContext
  alias GtfsPlanner.Gtfs.ReviewedApplyTransaction
  alias GtfsPlanner.Gtfs.RoutePattern
  alias GtfsPlanner.Gtfs.Stop
  alias GtfsPlanner.Gtfs.StopNaming
  alias GtfsPlanner.Gtfs.StopPlacement
  alias GtfsPlanner.Gtfs.StopReferences
  alias GtfsPlanner.Operations
  alias GtfsPlanner.Repo
  alias GtfsPlanner.Versions.GtfsVersion

  @editor_role "pathways_studio_editor"

  # How many times the create closure is rerun for a transient serialization
  # failure, a deadlock, or a generated ID taken by a concurrent insert. Three is
  # the route command's convention; a stop create is no more contentious than a
  # route create, so it gets the same budget rather than a number invented here.
  @attempts 3

  # The fields no surface in this package may write (INV-5). `stop_id` is the
  # key the feed, the rider information and every downstream tool is joined on;
  # `zone_id` belongs to Settings › Fares; the rest are structure rather than
  # content — moving a stop between types, or re-parenting it onto another
  # station, is a different operation with its own review, and the organization
  # and version come from the context and are not the form's to set anyway.
  @immutable_stop_fields ~w(
    stop_id
    zone_id
    organization_id
    gtfs_version_id
    location_type
    parent_station
  )

  # The reference kinds that mean "a rider can be at this stop". Read through
  # `StopReferences.serving?/2` rather than re-listed as queries here, so the
  # list of reference columns stays the one list (INV-1).
  @serving_kinds [:route_pattern_stops, :stop_times, :flex_hubs, :flex_first, :flex_last]

  @doc """
  Saves an editor's changes to an existing stop, audited in the same transaction (AC-13).

  `loaded_updated_at` is the `updated_at` the form was rendered from. If the row
  has moved on since, the answer is `{:error, :stale}` and nothing is written:
  two editors with the same stop open are better served by being told than by
  one of them silently overwriting the other.

  Answers `{:ok, stop}`, or one of

    * `{:review_required, :review | :far}` — the coordinates moved further than
      the correction band allows for a stop something serves. The stop is
      unchanged; step 14's review and step 16's `apply_move/4` take it from
      here. This is deliberately a top-level answer rather than an error: it is
      the next stage of the flow, not a failure.
    * `{:error, :stale | :forbidden | :not_found | :busy | :failed_audit}` — as
      for `create_stop/2`.
    * `{:error, %Ecto.Changeset{}}` — the draft is invalid.

  How far a move may go is `StopPlacement.move_band/2`'s question, not this
  command's (INV-3): a stop nothing serves is a correction at any distance,
  because there is no timetable to contradict, and a served stop is a correction
  to eight metres and a review beyond that.
  """
  @spec update_stop(Ecto.UUID.t(), map(), DateTime.t() | nil, AuditContext.t()) ::
          {:ok, Stop.t()}
          | {:review_required, :review | :far}
          | {:error,
             :stale
             | :forbidden
             | :not_found
             | :busy
             | :failed_audit
             | Ecto.Changeset.t()}
  def update_stop(stop_uuid, attrs, loaded_updated_at, %AuditContext{} = audit)
      when is_binary(stop_uuid) and is_map(attrs) do
    case run_command_transaction(fn ->
           apply_stop_update(stop_uuid, attrs, loaded_updated_at, audit)
         end) do
      # The band is a next stage, not a failure, so it is lifted out of the
      # transaction's `{:error, reason}` envelope here rather than at the
      # rollback, where it would still look like a refusal.
      {:error, {:review_required, band}} -> {:review_required, band}
      result -> result
    end
  end

  def update_stop(_stop_uuid, _attrs, _loaded_updated_at, _audit), do: {:error, :invalid_input}

  defp apply_stop_update(stop_uuid, attrs, loaded_updated_at, audit) do
    :ok = authorize_editor!(audit)
    _version = lock_published_version!(audit)

    stop = lock_stop!(stop_uuid, audit)
    :ok = refuse_if_stale(stop, loaded_updated_at)

    editable = Map.drop(stringify_keys(attrs), @immutable_stop_fields)

    case StopPlacement.move_band(move_metres(stop, editable), served?(stop)) do
      :correction -> update_stop_row(stop, editable, audit)
      band -> Repo.rollback({:review_required, band})
    end
  end

  # Scoped and locked, so a stop in another organization's version is invisible
  # rather than merely refused, and two concurrent updates serialise here rather
  # than at the write.
  defp lock_stop!(stop_uuid, audit) do
    if uuid?(stop_uuid) do
      query =
        from(stop in Stop,
          where:
            stop.id == ^stop_uuid and
              stop.organization_id == ^audit.organization_id and
              stop.gtfs_version_id == ^audit.gtfs_version_id,
          lock: "FOR UPDATE"
        )

      case Repo.one(query) do
        %Stop{} = stop -> stop
        nil -> Repo.rollback(:not_found)
      end
    else
      Repo.rollback(:not_found)
    end
  end

  # The form loaded the stop at a moment; if the row has changed since, the
  # draft describes a stop that no longer exists. A value that cannot be read
  # as a timestamp at all is treated the same way rather than trusted.
  defp refuse_if_stale(stop, loaded_updated_at) do
    if current?(stop.updated_at, loaded_updated_at), do: :ok, else: Repo.rollback(:stale)
  end

  # Compared at the precision the column actually keeps. `stops.updated_at` is
  # a `timestamp(0)` — a whole second — even though the schema declares
  # `utc_datetime_usec`, so a value read back from the database is truncated and
  # comparing it against the struct an insert returned would report every save
  # as stale. That also means two saves inside one second are not told apart by
  # this check; the `FOR UPDATE` on the stop row is what stops them interleaving,
  # and this check is what tells the editor. Recorded in the step learning.
  defp current?(current, loaded) do
    case load_timestamp(loaded) do
      {:ok, loaded} ->
        DateTime.compare(DateTime.truncate(current, :second), DateTime.truncate(loaded, :second)) ==
          :eq

      :error ->
        false
    end
  end

  defp load_timestamp(%DateTime{} = value), do: {:ok, value}
  defp load_timestamp(%NaiveDateTime{} = value), do: {:ok, DateTime.from_naive!(value, "Etc/UTC")}

  defp load_timestamp(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, parsed, _offset} -> {:ok, parsed}
      {:error, _reason} -> :error
    end
  end

  defp load_timestamp(_value), do: :error

  # How far the draft moves the stop, in metres. Zero when the draft does not
  # move it, which includes the case where it names only one of the two
  # coordinates: the changeset's own required-field rule is what answers that
  # one, and it answers it in the editor's own words rather than as a distance.
  defp move_metres(stop, editable) do
    with lat when not is_nil(lat) <- coordinate(editable["stop_lat"]),
         lon when not is_nil(lon) <- coordinate(editable["stop_lon"]),
         {from_lon, from_lat} <- coordinate_pair(stop) do
      StopPlacement.distance({from_lon, from_lat}, {lon, lat})
    else
      _unchanged_or_incomplete -> 0.0
    end
  end

  defp coordinate(%Decimal{} = value), do: Decimal.to_float(value)
  defp coordinate(value) when is_integer(value), do: value * 1.0
  defp coordinate(value) when is_float(value), do: value

  defp coordinate(value) when is_binary(value) do
    case Float.parse(value) do
      {parsed, _rest} -> parsed
      :error -> nil
    end
  end

  defp coordinate(_value), do: nil

  defp coordinate_pair(stop) do
    with lon when not is_nil(lon) <- coordinate(stop.stop_lon),
         lat when not is_nil(lat) <- coordinate(stop.stop_lat) do
      {lon, lat}
    else
      _unplaced -> nil
    end
  end

  # Whether anything in the feed puts riders at this stop. A pattern occurrence
  # and a stop time are both ways of saying the same thing, and either is
  # enough: a stop named only by `stop_times` — a trip whose pattern has not
  # been built — is still served, and treating it as unserved would let an
  # arbitrarily long move past the review this rule exists for.
  #
  # A flex service counts too. `StopReferences.usage/3` is not asked here
  # because it deliberately reports only this organization's own import; a
  # stop kept in a delivered feed still has riders on it, and the whole point
  # of the band is that "nobody rides here" is a claim about the data, not
  # about who loaded it.
  defp served?(stop) do
    Enum.any?(@serving_kinds, &StopReferences.serving?(&1, stop))
  end

  defp update_stop_row(stop, editable, audit) do
    changeset = Stop.editor_changeset(stop, editable)

    case Repo.update(changeset) do
      {:ok, updated} ->
        # The audit is written against the *pre-update* row with the changes as
        # the new values, which is the shape `Gtfs` diffs into a from/to per
        # field. Handing it the updated row instead would diff every written
        # field against itself and record an empty change.
        audit!(stop, audit, "updated", written_attrs(changeset))
        updated

      {:error, %Ecto.Changeset{} = failed} ->
        Repo.rollback(failed)
    end
  end

  # Exactly the fields Ecto changed, as strings. A draft that submits a field
  # unchanged contributes nothing to the log, so re-saving a form does not
  # manufacture a history of edits nobody made.
  defp written_attrs(changeset) do
    Map.new(changeset.changes, fn {field, value} -> {Atom.to_string(field), value} end)
  end

  @doc """
  Answers "what would moving this stop do", without writing anything (AC-14).

  Read-only in the strict sense: the routing calls happen first and outside any
  transaction, and the reads that follow take no row locks. A review is a
  question, and a question that blocks another editor's save for the length of
  a Geoapify round trip is a different feature.

  Answers `{:ok, review}` with

      %{distance_m, band, weekday_trips,
        patterns: [%{pattern_id, route_id, route_pattern_id, headsign,
                     from_name, to_name, outcome}],
        transfers: [%{label, before_m, after_m, min_transfer_time}],
        relief_points: [String.t()],
        suggestions: %{{from, to} => [[float()]]},
        fingerprint: String.t()}

  Each pattern's `outcome` is `:no_line` when it has neither a shape nor any
  segment, `{:routing_failed, reason}` when one of its pairs could not be
  routed, `{:blocked, :missing_sections}` when a section is still unresolved
  once the suggested points are substituted, `{:blocked, :trip_counts}` when
  `Alignments.shape_plan/2` finds linked trips that disagree with the pattern's
  visit count, and `:redraw` otherwise.

  The `fingerprint` is what `apply_move/4` checks before it writes: it covers
  everything this review read, so a review answered against a version of the
  data that has since moved on is refused rather than applied.
  """
  @spec move_review(Ecto.UUID.t(), StopPlacement.point(), AuditContext.t()) ::
          {:ok, map()} | {:error, atom()}
  def move_review(stop_uuid, point, %AuditContext{} = audit)
      when is_binary(stop_uuid) and is_tuple(point) do
    if authorize_editor?(audit) do
      case scoped_stop(stop_uuid, audit) do
        {:ok, stop} -> {:ok, build_review(stop, new_point(point), audit)}
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, :forbidden}
    end
  end

  def move_review(_stop_uuid, _point, _audit), do: {:error, :invalid_input}

  defp build_review(stop, new_point, audit) do
    distance = StopPlacement.distance(point_of(stop), new_point)
    band = StopPlacement.move_band(distance, served?(stop))

    # Outside the reads below, and outside any transaction: a routing request
    # is an external call and has no business inside a database transaction.
    routed =
      Alignments.suggest_stop_pairs(
        audit.organization_id,
        audit.gtfs_version_id,
        stop.stop_id,
        new_point
      )

    users = pair_users_for(routed.pairs, audit)

    %{
      distance_m: distance,
      band: band,
      weekday_trips: weekday_trips(stop, audit),
      patterns: review_patterns(users, routed, audit),
      transfers: review_transfers(stop, new_point, audit),
      relief_points: review_relief_points(stop, audit),
      suggestions: routed.suggestions,
      fingerprint: review_fingerprint(stop, new_point, users, audit)
    }
  end

  @spec new_point(StopPlacement.point()) :: StopPlacement.point()
  defp new_point({lon, lat}) when is_number(lon) and is_number(lat), do: {lon * 1.0, lat * 1.0}
  defp new_point(_point), do: {0.0, 0.0}

  # A stop with no coordinates cannot be measured from; the origin is used so
  # the review still answers rather than raising on malformed data.
  @spec point_of(Stop.t()) :: StopPlacement.point()
  defp point_of(stop) do
    with lon when not is_nil(lon) <- coordinate(stop.stop_lon),
         lat when not is_nil(lat) <- coordinate(stop.stop_lat) do
      {lon, lat}
    else
      _unplaced -> {0.0, 0.0}
    end
  end

  # Read without a lock, and only for existence: a review must not serialize
  # behind another editor's write, and it writes nothing that could conflict.
  defp scoped_stop(stop_uuid, audit) do
    if uuid?(stop_uuid) do
      query =
        from(stop in Stop,
          where:
            stop.id == ^stop_uuid and
              stop.organization_id == ^audit.organization_id and
              stop.gtfs_version_id == ^audit.gtfs_version_id
        )

      case Repo.one(query) do
        %Stop{} = stop -> {:ok, stop}
        nil -> {:error, :not_found}
      end
    else
      {:error, :not_found}
    end
  end

  # Every pattern that uses any of the pairs, once, with the pairs it uses
  # kept so the outcome can say which section it is talking about.
  defp pair_users_for(pairs, audit) do
    pairs
    |> Enum.flat_map(fn {from_id, to_id} ->
      audit.organization_id
      |> Alignments.pair_users(audit.gtfs_version_id, from_id, to_id)
      |> Enum.map(&Map.put(&1, :pairs, [{from_id, to_id}]))
    end)
    |> Enum.group_by(& &1.pattern_id)
    |> Enum.map(fn {_pattern_id, uses} ->
      first = hd(uses)

      %{
        first
        | pairs:
            uses
            |> Enum.flat_map(& &1.pairs)
            |> Enum.uniq()
            |> Enum.sort()
      }
    end)
    |> Enum.sort_by(&{&1.route_id, &1.route_pattern_id})
  end

  defp review_patterns(users, routed, audit) do
    names = stop_names(audit, users)

    Enum.map(users, fn user ->
      case load_pattern(user.pattern_id, audit) do
        nil -> review_row(user, nil, routed, names)
        %RoutePattern{} = pattern -> review_row(user, Alignments.resolve(pattern), routed, names)
      end
    end)
  end

  defp review_row(user, nil, _routed, _names) do
    # A pattern that disappeared between the pair scan and here is reported
    # rather than dropped: the review's job is to be complete.
    Map.merge(Map.drop(user, [:pairs]), %{
      headsign: nil,
      from_name: nil,
      to_name: nil,
      outcome: :no_line
    })
  end

  defp review_row(user, resolved, routed, names) do
    Map.merge(Map.drop(user, [:pairs]), %{
      headsign: resolved.pattern.headsign,
      from_name: Map.get(names, elem(hd(user.pairs), 0)),
      to_name: Map.get(names, elem(List.last(user.pairs), 1)),
      outcome: pattern_outcome(resolved.pattern, resolved, user.pairs, routed)
    })
  end

  defp load_pattern(pattern_id, audit) do
    Repo.one(
      from(pattern in RoutePattern,
        where:
          pattern.id == ^pattern_id and
            pattern.organization_id == ^audit.organization_id and
            pattern.gtfs_version_id == ^audit.gtfs_version_id
      )
    )
  end

  # The order matters and follows the spec: a pattern with nothing to draw is
  # `:no_line` whatever else is true, a pair that could not be routed says so
  # rather than blaming the data, and only then does a section that is still
  # unresolved count as blocked.
  defp pattern_outcome(pattern, resolved, pairs, routed) do
    cond do
      no_line?(pattern, resolved) ->
        :no_line

      failure = routing_failure(pairs, routed) ->
        {:routing_failed, failure}

      unresolved_section?(resolved, pairs, routed) ->
        {:blocked, :missing_sections}

      shape_plan_blocked?(pattern, resolved) ->
        {:blocked, :trip_counts}

      true ->
        :redraw
    end
  end

  defp no_line?(pattern, resolved) do
    is_nil(pattern.shape_id) and Enum.all?(resolved.sections, &(&1.kind == :missing))
  end

  defp routing_failure(pairs, routed) do
    Enum.find_value(pairs, fn pair ->
      case Map.fetch(routed.failed, pair) do
        {:ok, reason} -> reason
        :error -> nil
      end
    end)
  end

  # A section is still unresolved when the suggestions do not cover it and it
  # carries no points of its own. The suggested points are substituted in
  # memory, so a pair the review *can* route is never counted as missing.
  defp unresolved_section?(resolved, pairs, routed) do
    routed_pairs = pairs |> Enum.filter(&Map.has_key?(routed.suggestions, &1)) |> MapSet.new()

    Enum.any?(resolved.sections, fn section ->
      section.kind in [:missing, :blocked] and
        not MapSet.member?(routed_pairs, {section.from_stop_id, section.to_stop_id})
    end)
  end

  defp shape_plan_blocked?(pattern, resolved) do
    pattern
    |> Alignments.shape_plan(length(resolved.visits))
    |> Map.get(:blockers, [])
    |> Enum.any?()
  end

  defp stop_names(audit, users) do
    users
    |> Enum.flat_map(& &1.pairs)
    |> Enum.flat_map(fn {from_id, to_id} -> [from_id, to_id] end)
    |> Enum.uniq()
    |> stop_name_map(audit)
  end

  defp stop_name_map([], _audit), do: %{}

  defp stop_name_map(stop_ids, audit) do
    from(stop in Stop,
      where:
        stop.organization_id == ^audit.organization_id and
          stop.gtfs_version_id == ^audit.gtfs_version_id and
          stop.stop_id in ^stop_ids,
      select: {stop.stop_id, stop.stop_name}
    )
    |> Repo.all()
    |> Map.new()
  end

  # A transfer is a walking connection between two stops, so moving one end
  # changes how far a rider walks. Both distances are reported: the editor is
  # deciding whether the new walking distance is acceptable, which is not a
  # question with a before and no after.
  defp review_transfers(stop, new_point, audit) do
    usage = StopReferences.usage(audit.organization_id, audit.gtfs_version_id, stop)

    usage
    |> transfer_items()
    |> Enum.map(fn item -> transfer_row(item, stop, new_point, audit) end)
  end

  defp transfer_items(%{blocking: blocking, descriptive: descriptive}) do
    Enum.filter(blocking ++ descriptive, &(&1.key in [:transfers_from, :transfers_to]))
  end

  defp transfer_row(item, stop, new_point, audit) do
    detail = item.details |> hd() |> Map.fetch!(:detail)
    other_id = Map.get(detail, :to_stop_id) || Map.get(detail, :from_stop_id)
    other = other_point(other_id, audit)

    %{
      label: item.details |> hd() |> Map.fetch!(:label),
      before_m: distance_between(point_of(stop), other),
      after_m: distance_between(new_point, other),
      min_transfer_time: Map.get(detail, :min_transfer_time)
    }
  end

  @spec distance_between(StopPlacement.point(), StopPlacement.point() | nil) :: float() | nil
  defp distance_between(_from, nil), do: nil
  defp distance_between(from, to), do: StopPlacement.distance(from, to)

  defp other_point(other_id, audit) do
    query =
      from(stop in Stop,
        where:
          stop.organization_id == ^audit.organization_id and
            stop.gtfs_version_id == ^audit.gtfs_version_id and
            stop.stop_id == ^other_id,
        select: {stop.stop_lon, stop.stop_lat}
      )

    case Repo.one(query) do
      {lon, lat} when is_float(lon) and is_float(lat) -> {lon, lat}
      {%Decimal{} = lon, %Decimal{} = lat} -> {Decimal.to_float(lon), Decimal.to_float(lat)}
      _unplaced -> nil
    end
  end

  defp review_relief_points(stop, audit) do
    %{blocking: blocking, descriptive: descriptive} =
      StopReferences.usage(audit.organization_id, audit.gtfs_version_id, stop)

    (blocking ++ descriptive)
    |> Enum.filter(&(&1.key == :relief_points))
    |> Enum.flat_map(&Enum.map(&1.details, fn detail -> detail.label end))
  end

  defp weekday_trips(stop, audit) do
    %{blocking: blocking, descriptive: descriptive} =
      StopReferences.usage(audit.organization_id, audit.gtfs_version_id, stop)

    (blocking ++ descriptive)
    |> Enum.filter(&(&1.key == :route_pattern_stops))
    |> Enum.flat_map(& &1.details)
    |> Enum.map(&Map.get(&1, :weekday_trips, 0))
    |> Enum.sum()
  end

  # Everything this review read, hashed. A review answered against a version of
  # the data that has since moved on is refused by `apply_move/4` rather than
  # applied against facts that no longer hold.
  defp review_fingerprint(stop, new_point, users, audit) do
    pattern_ids = users |> Enum.map(& &1.pattern_id) |> Enum.sort()
    lock_versions = affected_lock_versions(stop, users, audit)

    :crypto.hash(
      :sha256,
      inspect({stop.id, stop.updated_at, point_of(stop), new_point, pattern_ids, lock_versions})
    )
    |> Base.encode16(case: :lower)
  end

  defp affected_lock_versions(stop, users, audit) do
    pairs = Enum.flat_map(users, & &1.pairs)

    from(segment in AlignmentSegment,
      where:
        segment.organization_id == ^audit.organization_id and
          segment.gtfs_version_id == ^audit.gtfs_version_id and
          segment.from_stop_id == ^stop.stop_id and
          segment.to_stop_id in ^Enum.map(pairs, &elem(&1, 1)),
      select: {segment.from_stop_id, segment.to_stop_id, segment.lock_version},
      order_by: [asc: segment.from_stop_id, asc: segment.to_stop_id]
    )
    |> Repo.all()
  end

  @doc """
  Creates a stop in a version, audited in the same transaction (AC-12).

  `attrs` is the editor's draft. A blank or absent `stop_id` is filled by the
  version's ID rule; anything the editor typed is kept as typed.

  Answers `{:ok, stop}`, or one of

    * `{:error, :forbidden}` — the actor is not an active editor of this
      organization. Nothing is written.
    * `{:error, :not_found}` — the version is another organization's, or is not
      published. Nothing is written.
    * `{:error, :failed_audit}` — the stop was created but its audit entry could
      not be written, so the whole transaction rolled back. This is INV-2's
      teeth: an unrecorded change is not a change.
    * `{:error, :busy}` — three attempts, each lost to a concurrent writer.
    * `{:error, %Ecto.Changeset{}}` — the draft is invalid, or its typed `stop_id`
      already exists in this version.

  A generated ID that loses a race to a concurrent insert is not an error: the
  closure is rerun so allocation sees the committed row and picks the next
  number. A *typed* ID that already exists is never re-allocated — the editor
  asked for that ID and renaming it silently would be worse than the error.
  """
  @spec create_stop(map(), AuditContext.t()) ::
          {:ok, Stop.t()}
          | {:error,
             :forbidden
             | :not_found
             | :busy
             | :failed_audit
             | Ecto.Changeset.t()}
  def create_stop(attrs, %AuditContext{} = audit) when is_map(attrs) do
    run_command_transaction(fn -> insert_stop(attrs, audit) end)
  end

  def create_stop(_attrs, _audit), do: {:error, :invalid_input}

  # The transaction body: authorize and lock before reading or writing anything,
  # so allocation and the scope check both see committed state.
  defp insert_stop(attrs, audit) do
    :ok = authorize_editor!(audit)
    _version = lock_published_version!(audit)

    scoped = scoped_attrs(attrs, audit)

    scoped
    |> with_allocated_stop_id(audit)
    |> insert_with_stop_changeset(audit)
  end

  # Scope comes from the context and cannot be overridden by the form.
  defp scoped_attrs(attrs, audit) do
    attrs
    |> stringify_keys()
    |> Map.merge(%{
      "organization_id" => audit.organization_id,
      "gtfs_version_id" => audit.gtfs_version_id
    })
  end

  # A typed ID is the editor's decision and is used as given. A blank one is
  # allocated under the version lock from committed rows.
  #
  # The origin travels with the attrs because it is what decides the error path
  # later: a *typed* duplicate is the editor's mistake to see, while a
  # *generated* one is a race worth retrying. By the time the insert runs, both
  # look identical — the ID is in the attrs either way.
  defp with_allocated_stop_id(%{"stop_id" => stop_id} = attrs, _audit)
       when is_binary(stop_id) and stop_id != "" do
    {:ok, Map.put(attrs, "stop_id_origin", :typed)}
  end

  defp with_allocated_stop_id(attrs, audit) do
    location_type = location_type_of(attrs)
    name = attrs["stop_name"] || ""

    existing = scoped_stop_ids(audit)
    garages = garage_ids(audit.organization_id)

    candidate =
      StopNaming.next_stop_id(existing, garages, {location_type, name})

    {:ok,
     attrs
     |> Map.put(
       "stop_id",
       Gtfs.unique_stop_id(audit.organization_id, audit.gtfs_version_id, candidate)
     )
     |> Map.put("stop_id_origin", :generated)}
  end

  defp insert_with_stop_changeset({:ok, attrs}, audit) do
    # `stop_id_origin` is this command's own bookkeeping, not a stop field, so
    # it is taken back out before the attrs reach the changeset.
    {origin, attrs} = Map.pop(attrs, "stop_id_origin")

    %Stop{}
    |> Stop.editor_changeset(attrs)
    |> Repo.insert()
    |> case do
      {:ok, stop} ->
        audit!(stop, audit, "created")
        stop

      {:error, %Ecto.Changeset{} = failed} ->
        if origin == :generated and stop_id_taken?(failed) do
          # Someone committed this number between allocation and insert. Rerun
          # the closure so allocation sees their row. A typed ID never gets
          # here: the editor asked for that ID, and renaming it silently to make
          # the error go away would be worse than showing them the error.
          Repo.rollback(:generated_collision)
        else
          Repo.rollback(failed)
        end
    end
  end

  # The unique index is on `(organization_id, gtfs_version_id, stop_id)`, and
  # Ecto attaches a composite unique error to the index's *first* field. So the
  # error arrives on `:organization_id`, not on `:stop_id`, and looking for
  # `:stop_id` in the errors would never fire — the command would report a
  # duplicate as if it were any other validation failure. The constraint name is
  # what actually identifies this case.
  @stop_id_constraint "stops_organization_id_gtfs_version_id_stop_id_index"

  # The one case worth a retry: we chose this ID and the database says it is
  # taken. The origin check lives at the call site, where it is still known.
  defp stop_id_taken?(%Ecto.Changeset{errors: errors}) do
    Enum.any?(errors, fn {_field, {_message, metadata}} ->
      metadata[:constraint_name] == @stop_id_constraint
    end)
  end

  defp location_type_of(attrs) do
    case attrs["location_type"] do
      type when is_integer(type) -> clamp_location_type(type)
      type when is_binary(type) -> clamp_location_type(parse_location_type(type))
      _other -> 0
    end
  end

  defp parse_location_type(value) do
    case Integer.parse(String.trim(value)) do
      {integer, _rest} -> integer
      :error -> 0
    end
  end

  # `StopNaming.next_stop_id/3`'s fallback takes a GTFS location type, and GTFS
  # defines exactly 0–4. Anything outside that is not a type we can slug.
  defp clamp_location_type(type) when type >= 0 and type <= 4, do: type
  defp clamp_location_type(_type), do: 0

  defp scoped_stop_ids(audit) do
    from(stop in Stop,
      where:
        stop.organization_id == ^audit.organization_id and
          stop.gtfs_version_id == ^audit.gtfs_version_id,
      select: stop.stop_id
    )
    |> Repo.all()
  end

  # A garage is not a stop, but it occupies a number in the same series, so a
  # stop ID equal to a garage ID would break the export's uniqueness rule.
  defp garage_ids(organization_id) do
    organization_id
    |> Operations.list_garages()
    |> Enum.map(& &1.garage_id)
    |> Enum.reject(&(is_nil(&1) or &1 == ""))
  end

  # Active organization editors only (AC-12), rechecked inside the transaction so
  # a denied actor writes nothing. Copied from `Routes.authorize_editor!/1` so
  # both command modules answer "is this actor allowed" identically.
  defp authorize_editor!(%AuditContext{} = audit) do
    if authorize_editor?(audit), do: :ok, else: Repo.rollback(:forbidden)
  end

  # The question the command helpers ask, without the rollback. `move_review/3`
  # is read-only and must not roll back a transaction it never opened, so it
  # asks rather than asserts.
  defp authorize_editor?(%AuditContext{} = audit) do
    with true <- uuid?(audit.actor_id),
         true <- uuid?(audit.organization_id),
         %UserOrgMembership{} = membership <-
           Accounts.get_user_org_membership(audit.actor_id, audit.organization_id),
         true <- is_nil(membership.deactivated_at) do
      editor_role?(membership.roles)
    else
      _other -> false
    end
  end

  defp editor_role?(roles) when is_list(roles), do: @editor_role in roles
  defp editor_role?(_roles), do: false

  # Published scope only. The create command locks the version row FOR UPDATE
  # before any read so ID allocation sees committed state.
  defp lock_published_version!(audit) do
    if uuid?(audit.organization_id) and uuid?(audit.gtfs_version_id) do
      query =
        from(version in GtfsVersion,
          where:
            version.id == ^audit.gtfs_version_id and
              version.organization_id == ^audit.organization_id and
              version.publication_status == "published",
          lock: "FOR UPDATE"
        )

      case Repo.one(query) do
        %GtfsVersion{} = version -> version
        nil -> Repo.rollback(:not_found)
      end
    else
      Repo.rollback(:not_found)
    end
  end

  # Mutation and audit commit together (INV-2). An unrecordable audit rolls the
  # whole closure back, so there is no committed stop without its history entry.
  # The entity type is an atom: `Gtfs.record_change_in_transaction/5` calls
  # `Atom.to_string/1` on it, matching how `Routes` audits a route.
  defp audit!(stop, audit, action, attrs \\ %{}) do
    case Gtfs.record_change_in_transaction(audit, :stop, stop, action, attrs) do
      {:ok, log} -> log
      {:error, _changeset} -> Repo.rollback(:failed_audit)
    end
  end

  # The route command's bounded-retry convention: rerun the whole serializable
  # closure on a transient serialization failure (40001), a deadlock (40P01) or
  # an explicitly identified generated-ID collision, at most three attempts.
  # Exhausted retries are `:busy`; every other failure returns unchanged.
  defp run_command_transaction(transaction, attempts \\ @attempts) do
    case run_apply_transaction(transaction) do
      {:ok, result} ->
        {:ok, result}

      {:retryable_conflict, _error} ->
        retry_command_transaction(transaction, attempts)

      {:error, :generated_collision} ->
        retry_command_transaction(transaction, attempts)

      {:error, reason} ->
        if retryable_conflict?(reason),
          do: retry_command_transaction(transaction, attempts),
          else: {:error, reason}
    end
  end

  defp retry_command_transaction(transaction, attempts) when attempts > 1,
    do: run_command_transaction(transaction, attempts - 1)

  defp retry_command_transaction(_transaction, _attempts), do: {:error, :busy}

  defp run_apply_transaction(transaction) do
    Application.get_env(
      :gtfs_planner,
      :reviewed_apply_transaction,
      ReviewedApplyTransaction.Repo
    ).run(transaction)
  rescue
    error in Postgrex.Error ->
      if retryable_conflict?(error),
        do: {:retryable_conflict, error},
        else: reraise(error, __STACKTRACE__)
  end

  defp retryable_conflict?(%Postgrex.Error{postgres: %{code: code}})
       when code in [
              :serialization_failure,
              "40001",
              :deadlock_detected,
              "40P01"
            ],
       do: true

  defp retryable_conflict?(_reason), do: false

  defp uuid?(value) when is_binary(value), do: match?({:ok, _}, Ecto.UUID.cast(value))
  defp uuid?(_value), do: false

  defp stringify_keys(attrs) do
    Map.new(attrs, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      {key, value} -> {key, value}
    end)
  end
end
