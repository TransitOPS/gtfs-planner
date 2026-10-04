defmodule GtfsPlanner.Gtfs.StopEditing do
  @moduledoc """
  The commands the stop editor runs, each one an audited transaction.

  Every write to a stop in this app goes through a function in this module, not
  through a changeset in a LiveView. That is what makes the audit guarantee
  checkable rather than aspirational: the audit entry and the mutation are
  written by the same closure, so there is no interleaving in which a stop
  changed and nobody wrote down who changed it.

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

  alias GtfsPlanner.Authorization
  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.Alignments
  alias GtfsPlanner.Gtfs.AlignmentSegment
  alias GtfsPlanner.Gtfs.AuditContext
  alias GtfsPlanner.Gtfs.ChangeLog
  alias GtfsPlanner.Gtfs.ReviewedApplyTransaction
  alias GtfsPlanner.Gtfs.RoutePattern
  alias GtfsPlanner.Gtfs.RoutePatternStop
  alias GtfsPlanner.Gtfs.Stop
  alias GtfsPlanner.Gtfs.StopNaming
  alias GtfsPlanner.Gtfs.StopPlacement
  alias GtfsPlanner.Gtfs.StopReferences
  alias GtfsPlanner.Gtfs.StopTime
  alias GtfsPlanner.Operations
  alias GtfsPlanner.Repo
  alias GtfsPlanner.Versions.GtfsVersion

  # How many times the create closure is rerun for a transient serialization
  # failure, a deadlock, or a generated ID taken by a concurrent insert. Three is
  # the route command's convention; a stop create is no more contentious than a
  # route create, so it gets the same budget rather than a number invented here.
  @attempts 3

  # The fields no stop editor surface may write. `stop_id` is the
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
  # list of reference columns stays the one list.
  @serving_kinds [:route_pattern_stops, :stop_times, :flex_hubs, :flex_first, :flex_last]

  @doc """
  Saves an editor's changes to an existing stop, audited in the same transaction.

  `loaded_updated_at` is the `updated_at` the form was rendered from. If the row
  has moved on since, the answer is `{:error, :stale}` and nothing is written:
  two editors with the same stop open are better served by being told than by
  one of them silently overwriting the other.

  Answers `{:ok, stop}`, or one of

    * `{:review_required, :review | :far}` — the coordinates moved further than
      the correction band allows for a stop something serves. The stop is
      unchanged; `move_review/3` and `apply_move/4` take it from
      here. This is deliberately a top-level answer rather than an error: it is
      the next stage of the flow, not a failure.
    * `{:error, :stale | :forbidden | :not_found | :busy | :failed_audit}` — as
      for `create_stop/2`.
    * `{:error, %Ecto.Changeset{}}` — the draft is invalid.

  How far a move may go is `StopPlacement.move_band/2`'s question, not this
  command's: a stop nothing serves is a correction at any distance,
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
    # Active organization editors only, rechecked inside the transaction
    # so a denied actor writes nothing. The membership row is locked before the
    # version and the stop, which is what a concurrent deactivation waits on.
    Authorization.lock_editor!(audit)
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
  # and this check is what tells the editor.
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
  Answers "what would moving this stop do", without writing anything.

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
    if Authorization.authorize_editor(audit) == :ok do
      case scoped_stop(stop_uuid, audit) do
        {:ok, stop} -> {:ok, build_review(stop, new_point(point), audit)}
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, :forbidden}
    end
  end

  def move_review(_stop_uuid, _point, _audit), do: {:error, :invalid_input}

  # What an impact answer says it does not compute: the pattern lines and the street
  # path are the native move review's, and the rest is outside the stop's references.
  @unmodeled [:street_path, :pattern_lines, :boarding_safety, :accessibility, :alerts]

  @doc """
  Answers "what would moving this stop affect", without a routing request, a lock
  or a write.

  This is the read half of `move_review/3`: the same distance, native band, weekday
  trips, patterns, transfers and relief points, read from one `StopReferences.usage/3`,
  plus every non-empty reference class. It never calls `Alignments.suggest_stop_pairs/4`,
  so it costs no street-routing request, and it takes no row lock, so it never waits
  behind another editor. The pattern lines a move would redraw and the walking path
  are decided by the native review, which is the only place that routes; `unmodeled`
  names what this answer leaves out.

  `point` is `{lon, lat}`: finite numbers with latitude within +/-90 and longitude
  within +/-180, anything else is `{:error, :invalid_input}`. A stop outside the audit's
  organization and version is `{:error, :not_found}` and a non-editor is
  `{:error, :forbidden}`.

      %{distance_m, band, served?, weekday_trips,
        patterns: [%{label, route_id, route_pattern_id, headsign, weekday_trips}],
        transfers: [%{label, before_m, after_m, min_transfer_time}],
        relief_points: [String.t()],
        references: [%{key, label, kind, count}],
        unmodeled: [atom()]}
  """
  @spec move_impact(Ecto.UUID.t(), StopPlacement.point(), AuditContext.t()) ::
          {:ok, map()} | {:error, :forbidden | :not_found | :invalid_input}
  def move_impact(stop_uuid, point, %AuditContext{} = audit) when is_binary(stop_uuid) do
    with {:ok, point} <- checked_point(point),
         :ok <- impact_authorization(audit),
         {:ok, stop} <- scoped_stop(stop_uuid, audit) do
      {:ok, build_impact(stop, point, audit)}
    end
  end

  def move_impact(_stop_uuid, _point, _audit), do: {:error, :invalid_input}

  defp checked_point({lon, lat})
       when is_number(lon) and is_number(lat) and lon >= -180 and lon <= 180 and lat >= -90 and
              lat <= 90,
       do: {:ok, {lon * 1.0, lat * 1.0}}

  defp checked_point(_point), do: {:error, :invalid_input}

  defp impact_authorization(audit) do
    case Authorization.authorize_editor(audit) do
      :ok -> :ok
      _refused -> {:error, :forbidden}
    end
  end

  defp build_impact(stop, point, audit) do
    usage = StopReferences.usage(audit.organization_id, audit.gtfs_version_id, stop)
    distance = StopPlacement.distance(point_of(stop), point)
    served? = served?(stop)

    %{
      distance_m: distance,
      band: StopPlacement.move_band(distance, served?),
      served?: served?,
      weekday_trips: weekday_trips(usage),
      patterns: impact_patterns(usage),
      transfers: review_transfers(stop, point, usage, audit),
      relief_points: review_relief_points(usage),
      references: impact_references(usage),
      unmodeled: @unmodeled
    }
  end

  # Sorted, because the reference read has no order of its own and an answer that lists
  # the same patterns in a different order on each read cannot be compared or cited.
  defp impact_patterns(usage) do
    rows =
      for %{label: label, detail: detail} = row <- pattern_details(usage) do
        %{
          label: label,
          route_id: detail.route_id,
          route_pattern_id: detail.route_pattern_id,
          headsign: detail.headsign,
          weekday_trips: Map.get(row, :weekday_trips, 0)
        }
      end

    Enum.sort_by(rows, &{&1.label, &1.route_pattern_id})
  end

  defp impact_references(%{blocking: blocking, descriptive: descriptive}) do
    Enum.map(blocking, &impact_reference(&1, :blocking)) ++
      Enum.map(descriptive, &impact_reference(&1, :descriptive))
  end

  defp impact_reference(item, kind),
    do: %{key: item.key, label: item.label, kind: kind, count: item.count}

  # The four text fields a batch may change, and the batch ceiling. Both are
  # engineering bounds of the helper that prepares batches, not editor limits.
  @metadata_fields ~w(stop_name stop_code stop_desc stop_url)
  @max_batch_rows 100
  @warning_others 3

  @doc """
  Reviews a batch of stop text changes without writing or locking anything.

  `rows` is a list of `%{stop_uuid: uuid, changes: %{field => value}}` where `field`
  is one of `stop_name`, `stop_code`, `stop_desc` and `stop_url` and `value` is a
  nonblank string. Each row is built through `Stop.editor_changeset/2`, so the native
  trimming and rules apply: a blank name on a located stop, a missing coordinate pair
  and a `stop_url` that is not `http` or `https` are the row's `errors`, and the batch
  is `valid?: false`. Nothing else about a stop can be named: IDs, coordinates,
  accessibility, parent and zone are refused as `:invalid_input`, as are an empty
  batch, a duplicate or malformed UUID, an empty `changes` and a blank or non-string
  value. More than 100 rows is `:too_many`. A UUID outside the audit's organization and
  version is `:not_found` for the whole call.

  Answers `{:ok, review}`:

      %{rows: [%{stop_uuid, stop_id, location_type, old: map, new: map, changed_fields:,
                 errors: %{field => [message]}, status: :changed | :unchanged | :invalid}],
        warnings: [%{kind: :duplicate_name, stop_uuid, name, others: [stop_id]}],
        valid?: boolean, changed: integer, unchanged: integer, fingerprint: String.t()}

  Rows are sorted by `stop_id`. `fingerprint` covers each stop's UUID, `updated_at`,
  type, current and proposed values, so a rename inside the same second as the review
  still changes it; `apply_metadata_batch/3` recomputes it under row locks.
  """
  @spec review_metadata_batch([map()], AuditContext.t()) ::
          {:ok, map()} | {:error, :forbidden | :invalid_input | :too_many | :not_found}
  def review_metadata_batch(rows, %AuditContext{} = audit) do
    with {:ok, rows} <- checked_metadata_rows(rows),
         :ok <- impact_authorization(audit),
         {:ok, stops} <- scoped_metadata_stops(rows, audit) do
      {:ok, build_metadata_review(rows, stops, audit)}
    end
  end

  # Input is validated before anything is read, so a malformed batch costs no query.
  defp checked_metadata_rows([]), do: {:error, :invalid_input}

  defp checked_metadata_rows(rows) when is_list(rows) and length(rows) > @max_batch_rows,
    do: {:error, :too_many}

  defp checked_metadata_rows(rows) when is_list(rows) do
    checked = Enum.map(rows, &checked_metadata_row/1)

    with false <- Enum.any?(checked, &(&1 == :error)),
         rows = Enum.map(checked, fn {:ok, row} -> row end),
         true <- distinct?(Enum.map(rows, & &1.stop_uuid)) do
      {:ok, rows}
    else
      _invalid -> {:error, :invalid_input}
    end
  end

  defp checked_metadata_rows(_rows), do: {:error, :invalid_input}

  defp checked_metadata_row(%{stop_uuid: uuid, changes: changes}) when is_binary(uuid) do
    with {:ok, uuid} <- Ecto.UUID.cast(uuid),
         true <- is_map(changes) and map_size(changes) > 0,
         true <- Enum.all?(changes, &metadata_change?/1) do
      {:ok, %{stop_uuid: uuid, changes: changes}}
    else
      _invalid -> :error
    end
  end

  defp checked_metadata_row(_row), do: :error

  defp metadata_change?({field, value}),
    do: field in @metadata_fields and is_binary(value) and String.trim(value) != ""

  defp distinct?(values), do: length(values) == length(Enum.uniq(values))

  defp scoped_metadata_stops(rows, audit) do
    uuids = Enum.map(rows, & &1.stop_uuid)

    stops =
      Repo.all(
        from(stop in Stop,
          where:
            stop.id in ^uuids and stop.organization_id == ^audit.organization_id and
              stop.gtfs_version_id == ^audit.gtfs_version_id
        )
      )

    if length(stops) == length(uuids), do: {:ok, stops}, else: {:error, :not_found}
  end

  # The one place a batch's rows are computed, so the review the editor sees and the
  # recomputation `apply_metadata_batch/3` makes under locks cannot disagree.
  defp build_metadata_review(rows, stops, audit) do
    rows |> metadata_rows(stops) |> metadata_review(audit)
  end

  defp metadata_rows(rows, stops) do
    stops_by_uuid = Map.new(stops, &{&1.id, &1})

    rows
    |> Enum.map(&metadata_row(&1, Map.fetch!(stops_by_uuid, &1.stop_uuid)))
    |> Enum.sort_by(& &1.stop_id)
  end

  defp metadata_review(built, audit) do
    %{
      rows: Enum.map(built, &Map.drop(&1, [:changeset, :requested, :updated_at])),
      warnings: duplicate_name_warnings(built, audit),
      valid?: Enum.all?(built, &(&1.status != :invalid)),
      changed: Enum.count(built, &(&1.status == :changed)),
      unchanged: Enum.count(built, &(&1.status == :unchanged)),
      fingerprint: metadata_fingerprint(built, audit)
    }
  end

  defp metadata_row(%{stop_uuid: uuid, changes: changes}, stop) do
    changeset = Stop.editor_changeset(stop, changes)
    new = metadata_values(Ecto.Changeset.apply_changes(changeset))
    old = metadata_values(stop)

    changed_fields =
      for field <- @metadata_fields,
          Map.has_key?(changes, field),
          new[field] != old[field],
          do: field

    %{
      stop_uuid: uuid,
      stop_id: stop.stop_id,
      location_type: stop.location_type,
      old: old,
      new: new,
      changed_fields: changed_fields,
      errors: changeset_messages(changeset),
      status: metadata_status(changeset.valid?, changed_fields),
      changeset: changeset,
      requested: Map.keys(changes),
      updated_at: stop.updated_at
    }
  end

  defp metadata_values(stop),
    do: Map.new(@metadata_fields, &{&1, Map.fetch!(stop, String.to_existing_atom(&1))})

  defp metadata_status(false, _changed_fields), do: :invalid
  defp metadata_status(true, []), do: :unchanged
  defp metadata_status(true, _changed_fields), do: :changed

  # The command's own messages keyed by field name, as the single-stop editor shows them.
  defp changeset_messages(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _whole, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
    |> Map.new(fn {field, messages} -> {Atom.to_string(field), messages} end)
  end

  # A changed name equal (trimmed, ignoring case) to another stop's name in the
  # version, or to another reviewed row's name, is a warning and never a merge. A
  # reviewed stop's own stored name is not "another stop's": a swap must not warn.
  defp duplicate_name_warnings(rows, audit) do
    renamed = Enum.filter(rows, &(&1.status == :changed and "stop_name" in &1.changed_fields))

    if renamed == [] do
      []
    else
      reviewed = Enum.map(rows, & &1.stop_uuid)
      names = renamed |> Enum.map(&name_key(&1.new["stop_name"])) |> Enum.uniq()

      elsewhere =
        from(stop in Stop,
          where:
            stop.organization_id == ^audit.organization_id and
              stop.gtfs_version_id == ^audit.gtfs_version_id and stop.id not in ^reviewed and
              fragment("lower(btrim(?))", stop.stop_name) in ^names,
          select: {stop.stop_id, fragment("lower(btrim(?))", stop.stop_name)}
        )
        |> Repo.all()
        |> Enum.map(fn {stop_id, name} -> {stop_id, name} end)

      # A generic node or boarding area may have no name; it has nothing to duplicate.
      siblings =
        for row <- rows,
            is_binary(row.new["stop_name"]),
            do: {row.stop_id, name_key(row.new["stop_name"])}

      for row <- renamed,
          key = name_key(row.new["stop_name"]),
          others =
            (elsewhere ++ siblings)
            |> Enum.filter(fn {stop_id, name} -> name == key and stop_id != row.stop_id end)
            |> Enum.map(&elem(&1, 0))
            |> Enum.uniq()
            |> Enum.sort(),
          others != [] do
        %{
          kind: :duplicate_name,
          stop_uuid: row.stop_uuid,
          name: row.new["stop_name"],
          others: Enum.take(others, @warning_others)
        }
      end
    end
  end

  @doc """
  Applies a reviewed batch of stop text changes: every changed row is saved, or none.

  `fingerprint` is the review's. The batch runs in one `run_command_transaction/1`
  attempt that takes the editor membership lock, then the published-version lock,
  then every stop `FOR UPDATE` in ascending `id` order, and only then recomputes the
  review from the locked rows and compares fingerprints. A stop that changed since the
  review (even inside the same second), a row that is invalid, a stop that is gone or a
  member who is no longer an editor writes nothing. Only the four text fields are
  written, one audit entry per changed stop with the actor; an unchanged row writes
  neither a row nor an audit entry.

  Answers `{:ok, %{stops: [Stop.t()], unchanged: integer}}` or
  `{:error, :stale_review | :invalid_rows | :forbidden | :not_found | :busy | :failed_audit |
  :invalid_input | :too_many}`. Input errors are answered before any transaction opens.
  """
  @spec apply_metadata_batch([map()], String.t(), AuditContext.t()) ::
          {:ok, %{stops: [Stop.t()], unchanged: non_neg_integer()}}
          | {:error,
             :stale_review
             | :invalid_rows
             | :forbidden
             | :not_found
             | :busy
             | :failed_audit
             | :invalid_input
             | :too_many}
  def apply_metadata_batch(rows, fingerprint, %AuditContext{} = audit) do
    with {:ok, rows} <- checked_metadata_rows(rows) do
      run_command_transaction(fn -> commit_metadata_batch(rows, fingerprint, audit) end)
    end
  end

  defp commit_metadata_batch(rows, fingerprint, audit) do
    Authorization.lock_editor!(audit)
    _version = lock_published_version!(audit)

    built = rows |> lock_metadata_stops!(audit) |> then(&metadata_rows(rows, &1))
    review = metadata_review(built, audit)

    unless matches_fingerprint?(fingerprint, review.fingerprint), do: Repo.rollback(:stale_review)
    unless review.valid?, do: Repo.rollback(:invalid_rows)

    stops =
      for %{status: :changed, changeset: changeset} <- built do
        updated = update_metadata_row!(changeset)
        audit!(changeset.data, audit, "updated", written_attrs(changeset))
        updated
      end

    %{stops: stops, unchanged: review.unchanged}
  end

  # Ascending `id` is the order every concurrent batch locks in, so two batches over
  # overlapping stops wait for each other instead of deadlocking.
  defp lock_metadata_stops!(rows, audit) do
    uuids = Enum.map(rows, & &1.stop_uuid)

    stops =
      Repo.all(
        from(stop in Stop,
          where:
            stop.id in ^uuids and stop.organization_id == ^audit.organization_id and
              stop.gtfs_version_id == ^audit.gtfs_version_id,
          order_by: stop.id,
          lock: "FOR UPDATE"
        )
      )

    if length(stops) == length(uuids), do: stops, else: Repo.rollback(:not_found)
  end

  defp update_metadata_row!(changeset) do
    case Repo.update(changeset) do
      {:ok, updated} -> updated
      {:error, %Ecto.Changeset{}} -> Repo.rollback(:invalid_rows)
    end
  end

  defp name_key(name), do: name |> String.trim() |> String.downcase()

  # Hashes content next to the whole-second `updated_at`, as the move and delete
  # fingerprints do: two saves inside one second are not told apart by the stamp.
  defp metadata_fingerprint(rows, audit) do
    digest({
      audit.organization_id,
      audit.gtfs_version_id,
      rows
      |> Enum.map(fn row ->
        {row.stop_uuid, row.updated_at, row.location_type, row.old,
         Map.take(row.new, row.requested)}
      end)
      |> Enum.sort()
    })
  end

  defp build_review(stop, new_point, audit) do
    usage = StopReferences.usage(audit.organization_id, audit.gtfs_version_id, stop)
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
      weekday_trips: weekday_trips(usage),
      patterns: review_patterns(users, routed, audit),
      transfers: review_transfers(stop, new_point, usage, audit),
      relief_points: review_relief_points(usage),
      suggestions: routed.suggestions,
      fingerprint:
        review_fingerprint(stop, new_point, users, affected_lock_versions(stop, users, audit))
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

  # The order matters: a pattern with nothing to draw is
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
  defp review_transfers(stop, new_point, usage, audit) do
    usage
    |> transfer_items()
    |> Enum.flat_map(& &1.details)
    |> Enum.map(fn detail -> transfer_row(detail, stop, new_point, audit) end)
  end

  defp transfer_items(%{blocking: blocking, descriptive: descriptive}) do
    Enum.filter(blocking ++ descriptive, &(&1.key in [:transfers_from, :transfers_to]))
  end

  # One row per transfer, not per direction: a stop with two outgoing transfers
  # has two walking distances to show.
  defp transfer_row(%{label: label, detail: detail}, stop, new_point, audit) do
    other_id = Map.get(detail, :to_stop_id) || Map.get(detail, :from_stop_id)
    other = other_point(other_id, audit)

    %{
      label: label,
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

  defp review_relief_points(%{blocking: blocking, descriptive: descriptive}) do
    (blocking ++ descriptive)
    |> Enum.filter(&(&1.key == :relief_points))
    |> Enum.flat_map(&Enum.map(&1.details, fn detail -> detail.label end))
  end

  defp weekday_trips(usage) do
    usage
    |> pattern_details()
    |> Enum.map(&Map.get(&1, :weekday_trips, 0))
    |> Enum.sum()
  end

  defp pattern_details(%{blocking: blocking, descriptive: descriptive}) do
    (blocking ++ descriptive)
    |> Enum.filter(&(&1.key == :route_pattern_stops))
    |> Enum.flat_map(& &1.details)
  end

  # Everything this review read, hashed. A review answered against a version of
  # the data that has since moved on is refused by `apply_move/4` rather than
  # applied against facts that no longer hold.
  #
  # The stop's *content* is hashed alongside its `updated_at`, not instead of
  # it. `stops.updated_at` is a `timestamp(0)` — a whole second — so two saves
  # inside one second are indistinguishable by timestamp alone, and a
  # fingerprint built on the timestamp alone would let a name edit through
  # unreviewed. Hashing the fields the review actually read closes that, and
  # is also what makes the fingerprint mean what it says: it covers the
  # review's inputs, not merely a clock.
  defp review_fingerprint(stop, new_point, users, lock_versions) do
    pattern_ids = users |> Enum.map(& &1.pattern_id) |> Enum.sort()

    digest({
      stop.id,
      stop.updated_at,
      point_of(stop),
      new_point,
      pattern_ids,
      lock_versions,
      stop_content(stop)
    })
  end

  # The hash of a term's whole binary encoding, in a form that does not
  # depend on map key order. `inspect/1` is not used here: it stops printing a
  # collection after 50 elements, so for a stop on many patterns or segments
  # the later elements would never reach the hash and a change to them would
  # read as no change at all.
  defp digest(term) do
    :crypto.hash(:sha256, :erlang.term_to_binary(term, [:deterministic]))
    |> Base.encode16(case: :lower)
  end

  # The stop fields a review reads or reports on. Deliberately the stop's own
  # columns and not the whole struct: `updated_at` is already covered above,
  # and the ID and scope are covered by the same `stop.id` the rest is.
  defp stop_content(stop) do
    {stop.stop_name, stop.stop_desc, stop.stop_code, stop.tts_stop_name, stop.stop_url}
  end

  # Both directions, not just segments *from* the stop. The moved stop is
  # the `from` of one pair and the `to` of the other, so a query that only
  # looked at `from_stop_id` would cover the segment the redraw is about to
  # rewrite for one direction and miss it entirely for the other — and a
  # fingerprint that misses a row the apply writes is not a fingerprint.
  defp affected_lock_versions(stop, users, audit) do
    pairs = Enum.flat_map(users, & &1.pairs)
    tos = Enum.map(pairs, &elem(&1, 1))

    from(segment in AlignmentSegment,
      where:
        segment.organization_id == ^audit.organization_id and
          segment.gtfs_version_id == ^audit.gtfs_version_id and
          (segment.from_stop_id == ^stop.stop_id or segment.to_stop_id == ^stop.stop_id) and
          segment.to_stop_id in ^tos,
      select:
        {segment.from_stop_id, segment.to_stop_id, segment.from_occurrence_id,
         segment.lock_version},
      order_by: [
        asc: segment.from_stop_id,
        asc: segment.to_stop_id,
        asc: segment.from_occurrence_id,
        asc: segment.id
      ]
    )
    |> Repo.all()
  end

  @doc """
  Applies a reviewed move, audited in the same transaction.

  `attrs` is the editor's draft and `options` is what the review it was
  answered against produced:

      %{lines: :redraw | :keep, answer: :same | :new | nil,
        fingerprint: String.t(), suggestions: %{{from, to} => [[float()]]}}

  The `fingerprint` is re-checked inside the transaction before anything is
  written, so a review answered against a version of the data that has since
  moved on is refused rather than applied against facts that no longer hold.

  Answers `{:ok, %{stop:, redrawn:, stale:}}`, where `redrawn` and `stale` are
  `RoutePattern` UUIDs. Or one of

    * `{:error, :stale_review}` — the review's fingerprint no longer matches.
      Nothing is written.
    * `{:error, :answer_required}` — the move is past the `:far` band and the
      editor has not answered. Nothing is written. This is a question the
      editor has to answer, not a failure: at that distance the stop may be
      the wrong stop entirely, and only the editor knows.
    * `{:error, :new_stop}` — the editor answered `:new`, meaning this is a
      different stop rather than a moved one. Nothing is written; the caller
      starts an add at the pin instead.
    * `{:error, :forbidden | :not_found | :busy | :failed_audit}` — as for
      `create_stop/2`.
    * `{:error, %Ecto.Changeset{}}` — the draft is invalid.

  **A blocked pattern never rolls the move back.** Lines that cannot be
  redrawn are reported in `stale` and their existing shape rows and digest are
  left exactly as they were, because `materialize_pattern!/4` rolls the whole
  transaction back when handed blockers. A stop that riders can no longer reach
  is still a stop riders can no longer reach; refusing the coordinates over a
  line that was already stale would be the wrong trade.
  """
  @spec apply_move(Ecto.UUID.t(), map(), map(), AuditContext.t()) ::
          {:ok, %{stop: Stop.t(), redrawn: [Ecto.UUID.t()], stale: [Ecto.UUID.t()]}}
          | {:error,
             :stale_review
             | :answer_required
             | :new_stop
             | :forbidden
             | :not_found
             | :busy
             | :failed_audit
             | Ecto.Changeset.t()}
  def apply_move(stop_uuid, attrs, options, %AuditContext{} = audit)
      when is_binary(stop_uuid) and is_map(attrs) and is_map(options) do
    run_command_transaction(fn -> commit_move(stop_uuid, attrs, options, audit) end)
  end

  def apply_move(_stop_uuid, _attrs, _options, _audit), do: {:error, :invalid_input}

  # The transaction body, in the order the steps are named in: authorize,
  # lock, re-check, decide, write, redraw.
  defp commit_move(stop_uuid, attrs, options, audit) do
    Authorization.lock_editor!(audit)
    _version = lock_published_version!(audit)

    stop = lock_stop!(stop_uuid, audit)
    new_point = new_point(Map.get(options, :point) || coords_from(attrs))

    {:ok, reviewed} = refuse_moved_review(stop, new_point, options, audit)
    :ok = refuse_unanswered_far_move(stop, new_point, options)

    editable = move_attrs(attrs, new_point, audit)

    case Repo.update(Stop.editor_changeset(stop, editable)) do
      {:ok, moved} ->
        audit_move(stop, moved, attrs, new_point, options, audit)

        %{redrawn: redrawn, stale: stale} =
          redraw_after_move(moved, reviewed, options, audit)

        %{stop: moved, redrawn: redrawn, stale: stale}

      {:error, %Ecto.Changeset{} = failed} ->
        Repo.rollback(failed)
    end
  end

  # The review's fingerprint covers the stop's `updated_at`, both points, the
  # patterns the move touches and their segment lock versions. It is
  # recomputed here from the *pre-move* stop, so `review_fingerprint/4` sees
  # the same old point it saw when the editor was shown the review. Reading
  # the stop again after the write would compare the new point against itself
  # and never match — which would make every apply answer `:stale_review`.
  #
  # Answers `{:ok, lock_versions}`, the segment versions the matching
  # fingerprint covered.
  defp refuse_moved_review(stop, new_point, options, audit) do
    users = pair_users_for(Alignments.stop_pairs(audit, stop), audit)

    lock_versions = affected_lock_versions(stop, users, audit)
    expected = review_fingerprint(stop, new_point, users, lock_versions)

    if matches_fingerprint?(Map.get(options, :fingerprint), expected) do
      {:ok, lock_versions}
    else
      Repo.rollback(:stale_review)
    end
  end

  defp matches_fingerprint?(given, expected) when is_binary(given) and is_binary(expected) do
    byte_size(given) == byte_size(expected) and Plug.Crypto.secure_compare(given, expected)
  end

  defp matches_fingerprint?(_given, _expected), do: false

  # Past the far band the question is not "how far" but "is this the same
  # stop". `:new` is an answer, not a refusal: the caller starts an add at the
  # pin and leaves this stop alone.
  defp refuse_unanswered_far_move(stop, new_point, options) do
    band =
      StopPlacement.move_band(StopPlacement.distance(point_of(stop), new_point), served?(stop))

    case {band, Map.get(options, :answer)} do
      {:far, nil} -> Repo.rollback(:answer_required)
      {:far, :new} -> Repo.rollback(:new_stop)
      _other -> :ok
    end
  end

  # The draft's own editor fields, plus the coordinates the move decided. The
  # immutable fields are dropped here as they are in `update_stop/4`, so a
  # hidden field in the form cannot re-parent the stop or rename it on the way
  # past this command.
  defp move_attrs(attrs, {lon, lat}, audit) do
    attrs
    |> stringify_keys()
    |> Map.drop(@immutable_stop_fields)
    |> Map.merge(%{
      "stop_lat" => Decimal.from_float(lat),
      "stop_lon" => Decimal.from_float(lon),
      "organization_id" => audit.organization_id,
      "gtfs_version_id" => audit.gtfs_version_id
    })
  end

  defp coords_from(attrs) do
    attrs = stringify_keys(attrs)
    {coordinate(attrs["stop_lon"]) || 0.0, coordinate(attrs["stop_lat"]) || 0.0}
  end

  # The distance is the point of the audit entry: a move of 330 m and a move
  # of 12 m leave the same two fields changed, and the history view has to be
  # able to say which happened.
  defp audit_move(stop, moved, attrs, new_point, options, audit) do
    attrs =
      %{
        "stop_lat" => Decimal.to_float(moved.stop_lat),
        "stop_lon" => Decimal.to_float(moved.stop_lon)
      }
      |> Map.merge(
        Map.take(stringify_keys(attrs), ~w(stop_name stop_desc stop_code tts_stop_name stop_url
                                          platform_code wheelchair_boarding))
      )
      |> Map.put("move", %{
        "distance_m" => StopPlacement.distance(point_of(stop), new_point),
        "lines" => to_string(Map.get(options, :lines, :keep))
      })

    audit!(stop, audit, "updated", attrs)
  end

  # `:redraw` hands the geometry to `Alignments.redraw_stop_pairs!/3`; `:keep`
  # writes the coordinates and nothing else, so every pattern the review listed
  # is stale by definition — the editor has decided the lines stay as they are.
  defp redraw_after_move(moved, reviewed, options, audit) do
    case Map.get(options, :lines, :keep) do
      :redraw ->
        case Alignments.redraw_stop_pairs!(
               audit.organization_id,
               audit.gtfs_version_id,
               %{
                 suggestions: Map.get(options, :suggestions, %{}),
                 failed: Map.get(options, :failed, %{}),
                 reviewed_lock_versions: reviewed_lock_versions(reviewed),
                 audit_context: audit
               }
             ) do
          %{redrawn: redrawn, stale: stale} ->
            %{
              redrawn: Enum.map(redrawn, & &1.pattern_id),
              stale: Enum.map(stale, & &1.pattern_id)
            }

          {:error, reason} ->
            Repo.rollback(reason)
        end

      _keep ->
        affected = pair_users_for(Alignments.stop_pairs(audit, moved), audit)
        %{redrawn: [], stale: Enum.map(affected, & &1.pattern_id)}
    end
  end

  # The segment lock versions the fingerprint check just matched against the
  # review, keyed the way the redraw looks segments up. The redraw reads each
  # segment again before writing it, and a segment another editor saved in
  # between is refused there instead of being overwritten.
  defp reviewed_lock_versions(reviewed) do
    Map.new(reviewed, fn {from, to, occurrence, version} -> {{from, to, occurrence}, version} end)
  end

  @doc """
  Answers "what would deleting this stop remove", without writing.

  Read-only in the same sense `move_review/3` is: it takes no row locks, so
  asking the question does not serialize behind another editor's save.

  Answers `{:ok, %{blocking:, descriptive:, fingerprint:}}`, where `blocking`
  and `descriptive` are `StopReferences.usage/3`'s items. **Any** blocking item
  refuses the delete. The refusal is on the *presence* of the item, never on a
  count reaching a threshold: `StopReferences.counts/3` is structurally unable
  to see the `via: :fk_uuid` references — `stop_levels` and `journal_entries`
  match on `stops.id`, and an unimported stop ID has none — so a count-based
  refusal would be passing for the wrong reason on exactly the rows a station
  delete most needs to refuse on. `usage/3` runs the ref's own scoped query and
  so sees all three `via` shapes.

  `fingerprint` covers the usage and the stop itself, and is what
  `delete_stop/3` re-checks: a reference created after the editor read this
  answer must refuse the delete rather than cascade a row nobody saw.
  """
  @spec delete_review(Ecto.UUID.t(), AuditContext.t()) ::
          {:ok, map()} | {:error, atom()}
  def delete_review(stop_uuid, %AuditContext{} = audit) when is_binary(stop_uuid) do
    if Authorization.authorize_editor(audit) == :ok do
      case scoped_stop(stop_uuid, audit) do
        {:ok, stop} -> {:ok, build_delete_review(stop, audit)}
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, :forbidden}
    end
  end

  def delete_review(_stop_uuid, _audit), do: {:error, :invalid_input}

  defp build_delete_review(stop, audit) do
    usage = StopReferences.usage(audit.organization_id, audit.gtfs_version_id, stop)

    Map.merge(usage, %{fingerprint: delete_fingerprint(stop, usage, audit)})
  end

  # Everything the review read, hashed: the stop's own identity and content,
  # and every reference item with its count. The stop's content is included
  # rather than only its `updated_at` because that column is a whole second
  # (see `review_fingerprint/4`), and a stop renamed inside the same second
  # would otherwise pass a fingerprint that no longer describes it.
  defp delete_fingerprint(stop, usage, audit) do
    items =
      (usage.blocking ++ usage.descriptive)
      |> Enum.map(&{&1.key, &1.count})
      |> Enum.sort()

    digest({
      stop.id,
      stop.stop_id,
      stop.updated_at,
      stop_content(stop),
      items,
      audit.organization_id,
      audit.gtfs_version_id
    })
  end

  @doc """
  Deletes a stop and exactly the descriptive rows `delete_review/2` listed,
  audited in the same transaction.

  Answers `{:ok, %{removed: %{atom() => non_neg_integer()}}}`, or one of

    * `{:error, {:blocked, items}}` — a blocking reference exists. Nothing is
      written and every blocking row is still there. A station with a level, a
      `stop_levels` row, a journal entry or an editing status is in this
      case: those rows are the station's structure, and cascading them would
      destroy a drawing an editor built rather than tidy up after a stop.
    * `{:error, :stale_review}` — the review's fingerprint no longer matches,
      so a reference appeared or disappeared since the editor read the answer.
    * `{:error, :forbidden | :not_found | :busy | :failed_audit}` — as for
      `create_stop/2`.

  A stop is never deleted through a foreign-key cascade. The descriptive rows
  are deleted explicitly, by the same `StopReferences` entries that listed
  them, so "exactly those rows" is a property of this function rather than of
  whatever constraints the schema happens to carry.
  """
  @spec delete_stop(Ecto.UUID.t(), String.t(), AuditContext.t()) ::
          {:ok, %{removed: %{atom() => non_neg_integer()}}}
          | {:error,
             {:blocked, [map()]}
             | :stale_review
             | :forbidden
             | :not_found
             | :busy
             | :failed_audit}
  def delete_stop(stop_uuid, fingerprint, %AuditContext{} = audit)
      when is_binary(stop_uuid) and is_binary(fingerprint) do
    run_command_transaction(fn -> commit_delete(stop_uuid, fingerprint, audit) end)
  end

  def delete_stop(_stop_uuid, _fingerprint, _audit), do: {:error, :invalid_input}

  defp commit_delete(stop_uuid, fingerprint, audit) do
    Authorization.lock_editor!(audit)
    _version = lock_published_version!(audit)

    stop = lock_stop!(stop_uuid, audit)
    usage = StopReferences.usage(audit.organization_id, audit.gtfs_version_id, stop)

    if usage.blocking != [] do
      Repo.rollback({:blocked, usage.blocking})
    else
      apply_delete(stop, usage, fingerprint, audit)
    end
  end

  # The descriptive rows go before the stop, and the audit entry is written
  # before the stop row, in the same transaction, so a deleted stop always has
  # the record of what went with it — and never has one while rows still name it,
  # which is what a cascade would do and what makes a cascade unreviewable.
  # The audit is written in the same transaction, so a deleted stop with no
  # history entry rolls back.
  defp apply_delete(stop, usage, fingerprint, audit) do
    if matches_fingerprint?(fingerprint, delete_fingerprint(stop, usage, audit)) do
      removed = Enum.reduce(usage.descriptive, %{}, &delete_descriptive_item(&1, &2, stop))

      audit!(stop, audit, "deleted", %{"removed" => removed})

      case Repo.delete(stop) do
        {:ok, _deleted} -> %{removed: removed}
        {:error, %Ecto.Changeset{} = failed} -> Repo.rollback(failed)
      end
    else
      Repo.rollback(:stale_review)
    end
  end

  # One entry from `StopReferences.all/0` at a time, through its own
  # `scope_query/2`. The delete therefore removes exactly the rows the review
  # counted, on the same scope and the same column, and a new reference kind
  # becomes deletable by adding it to that one list.
  defp delete_descriptive_item(item, removed, stop) do
    case StopReferences.fetch(item.key) do
      nil ->
        # A review item with no catalog entry cannot be deleted, and leaving
        # the row would leave the stop's ID in a file the export writes.
        # Refusing is the honest answer; this is unreachable while
        # `usage/3` and `all/0` are built from the same list.
        Repo.rollback(:stale_review)

      ref ->
        {count, _} = Repo.delete_all(StopReferences.scope_query(ref, stop))
        Map.update(removed, StopReferences.report_key(ref), count, &(&1 + count))
    end
  end

  @doc """
  Answers "what would replacing the old stop with the new one change".

  Read-only, like `delete_review/2` and `move_review/3`: no locks, no writes, so
  asking does not serialize behind another editor's save.

  Answers `{:ok, %{changes: [...], dropped: [...], fingerprint: ...}}`, or
  `{:error, {:refused, reasons}}` when the replace must not happen at all.

  ## The refusals, and why each is a refusal

    * `:same_stop` — there is nothing to replace.
    * `:station` — either stop is a station (`location_type` 1). Rewriting a
      reference onto a station would attach a timetable row to a drawing.
    * `:child` — either stop has a parent. A bay's references belong to the
      station's, and merging them silently would lose which is which.
    * `:type_mismatch` — the two stops' `location_type`s differ. A stop is not
      interchangeable with an entrance or a station node.
    * `{:consecutive_pattern, route_pattern_ids}` — a pattern that visits the
      old stop and the new one **adjacent**. After the rewrite it would visit
      the new one twice in a row, which no pattern means.
    * `{:consecutive_trip, count}` — the same thing in the timetables, counted
      rather than listed because a trip has no ID to hand back.

  Both adjacency checks read `position` and `stop_sequence` rather than ID
  order. For example, Route 12 visiting `…, 1433, 1391, …` may replace 1433 with
  1434 but not with 1391.

  ## The effects

  Every entry in `StopReferences.all/0` that has rows contributes one
  `change` — the rows the replace will rewrite — and every row that a rewrite
  would drop contributes one `drop`. A `change` is
  `%{key:, label:, count:, rule:, details:}`; a `drop` adds `:kept`, the row
  that survives in its place. Only the kinds a person needs to act on carry
  `details`: a deadhead row carries both minutes, because "5 minutes" and "20
  minutes" for the same garage pair is the whole question.

  A rewrite that would land on a row the replacement already has is a **drop,
  not a change**: the existing row is kept and the old one deleted, per
  `:rewrite_keep_existing`. Which rows those are is decided by the entry's own
  `collision_key`, read off the catalog — so this function and
  `replace_stop/4` never name a table. `:rekey_segments` drops a segment
  that would become `(new, new)` for the same reason.

  `:refuse` entries are the station rows: a replace is refused
  outright while a pathway, a level, a journal entry or an editing status
  exists, because moving references onto a different stop would orphan the
  drawing they describe.

  `fingerprint` covers both stops' content and every count, and is what
  `replace_stop/4` re-checks.
  """
  # A kind is a summary, not a data dump: a replace touching ten thousand stop
  # times must not load ten thousand rows to draw a dialog. The cap is far above
  # any single stop's realistic reference count.
  @replace_row_limit 5_000

  @spec replace_review(Ecto.UUID.t(), Ecto.UUID.t(), AuditContext.t()) ::
          {:ok, map()}
          | {:error, {:refused, [atom()]} | :forbidden | :not_found | :invalid_input}
  def replace_review(old_uuid, new_uuid, %AuditContext{} = audit)
      when is_binary(old_uuid) and is_binary(new_uuid) do
    if Authorization.authorize_editor(audit) == :ok do
      with {:ok, old} <- scoped_stop(old_uuid, audit),
           {:ok, new} <- scoped_stop(new_uuid, audit) do
        build_replace_review(old, new, audit)
      end
    else
      {:error, :forbidden}
    end
  end

  def replace_review(_old_uuid, _new_uuid, _audit), do: {:error, :invalid_input}

  defp build_replace_review(old, new, audit) do
    case replace_refusals(old, new) do
      [] ->
        changes = Enum.map(StopReferences.all(), &replace_change(&1, old, new))
        dropped = Enum.flat_map(changes, & &1.drops)
        effects = Enum.map(changes, &public_change/1)

        {:ok,
         %{
           changes: effects,
           dropped: dropped,
           fingerprint:
             replace_fingerprint(old, new, Enum.map(effects, &{&1.key, &1.count}), audit)
         }}

      reasons ->
        {:error, {:refused, reasons}}
    end
  end

  # The refusal list is built in a fixed order so the same state always answers
  # with the same reasons — a review an editor reopens after saving should not
  # present a different list than the one they were shown.
  defp replace_refusals(old, new) do
    cond do
      old.id == new.id -> [:same_stop]
      station?(old) or station?(new) -> [:station]
      old.parent_station || new.parent_station -> [:child]
      old.location_type != new.location_type -> [:type_mismatch]
      true -> []
    end
    |> Kernel.++(station_refusal_reasons(old))
    |> Kernel.++(consecutive_reasons(old, new))
  end

  defp station?(stop), do: stop.location_type == 1

  # `:refuse` entries are rows a replace cannot carry across. Listed as one
  # reason per kind, so an editor is told *what* is in the way rather than
  # "some station row".
  defp station_refusal_reasons(old) do
    StopReferences.all()
    |> Enum.filter(&(&1.replace == :refuse and replace_count(&1, old) > 0))
    |> Enum.map(&{:blocked, &1.key})
  end

  # A pattern or trip that already visits the replacement immediately before or
  # after the old stop would visit it twice in a row after the rewrite. Found
  # with a self-join on the adjacent `position` / `stop_sequence`, so the
  # question is answered for every pattern and every trip in one query each
  # rather than one per row.
  defp consecutive_reasons(old, new) do
    consecutive_pattern(old, new) ++ consecutive_trip(old, new)
  end

  defp consecutive_pattern(old, new) do
    patterns =
      from(rps in RoutePatternStop,
        join: other in RoutePatternStop,
        on:
          other.route_pattern_id == rps.route_pattern_id and
            other.stop_id == ^new.stop_id and
            other.position in [rps.position - 1, rps.position + 1],
        where:
          rps.stop_id == ^old.stop_id and
            rps.organization_id == ^old.organization_id and
            rps.gtfs_version_id == ^old.gtfs_version_id and
            other.organization_id == ^old.organization_id and
            other.gtfs_version_id == ^old.gtfs_version_id,
        select: rps.route_pattern_id,
        distinct: true
      )
      |> Repo.all()
      |> Enum.sort()

    if patterns == [], do: [], else: [{:consecutive_pattern, patterns}]
  end

  defp consecutive_trip(old, new) do
    count =
      from(st in StopTime,
        join: other in StopTime,
        on:
          other.trip_id == st.trip_id and
            other.stop_id == ^new.stop_id and
            other.stop_sequence in [st.stop_sequence - 1, st.stop_sequence + 1],
        where:
          st.stop_id == ^old.stop_id and
            st.organization_id == ^old.organization_id and
            st.gtfs_version_id == ^old.gtfs_version_id and
            other.organization_id == ^old.organization_id and
            other.gtfs_version_id == ^old.gtfs_version_id,
        select: fragment("count(distinct ?)", st.trip_id)
      )
      |> Repo.one()

    if count && count > 0, do: [{:consecutive_trip, count}], else: []
  end

  defp replace_change(%{replace: :refuse} = ref, old, _new) do
    # Listed so the review accounts for every kind, but a non-zero count is a
    # refusal, not a change — see `station_refusal_reasons/1`.
    %{
      key: ref.key,
      label: ref.label,
      count: replace_count(ref, old),
      rule: ref.replace,
      drops: []
    }
  end

  # A `:drop` kind — the old stop's translations — is the simplest effect there
  # is: every row goes and nothing takes its place. Each row is still listed
  # individually, because a translation is a person's work in a language and
  # "3 translations removed" does not say which.
  defp replace_change(%{replace: :drop} = ref, old, _new) do
    rows = replace_rows(ref, old)

    drops =
      Enum.map(rows, fn row ->
        %{
          key: ref.key,
          label: ref.label,
          count: 1,
          kept: nil,
          details: translate_details(row)
        }
      end)

    %{key: ref.key, label: ref.label, count: length(rows), rule: ref.replace, drops: drops}
  end

  defp replace_change(ref, old, new) do
    rows = replace_rows(ref, old)
    drops = Enum.flat_map(rows, &collision_drop(ref, &1, old, new))

    %{key: ref.key, label: ref.label, count: length(rows), rule: ref.replace, drops: drops}
  end

  defp translate_details(%{language: language, field_name: field, translation: text}) do
    [%{language: language, field: field, translation: text}]
  end

  defp translate_details(_row), do: []

  defp public_change(%{drops: drops} = change) do
    Map.put(change, :dropped, length(drops))
  end

  # The rows a rewrite would put on top of a row the replacement already has.
  # `collision_key` is the entry's own uniqueness columns, so this is one
  # grouped query per entry and never a table name. A row whose
  # rewritten key matches an existing row is dropped; the existing row is kept.
  defp collision_drop(ref, row, old, new) when is_map(row) do
    cond do
      segment_self_pair?(ref, row, old, new) ->
        [segment_drop(ref, row)]

      collision?(ref, row, old, new) ->
        [
          %{
            key: ref.key,
            label: ref.label,
            count: 1,
            kept: collision_kept(ref, row, old, new),
            details: replace_details(ref, row, new)
          }
        ]

      true ->
        []
    end
  end

  # `(new, new)` names no journey: a segment whose two ends would become the
  # same stop is dropped rather than written, because it would draw a zero
  # length line and read as real service.
  # Both ends of the *rewritten* pair, not of the stored one: a segment
  # `1391 -> 1433` does not name the same stop twice until the replace turns
  # its second end into `1391`.
  defp segment_self_pair?(ref, row, old, new) do
    match?(%{replace: :rekey_segments}, ref) and
      Enum.all?([row.from_stop_id, row.to_stop_id], fn stop_id ->
        stop_id == old.stop_id or stop_id == new.stop_id
      end) and
      Enum.all?([row.from_stop_id, row.to_stop_id], fn stop_id ->
        rewritten_segment_end(ref, stop_id, old, new) == new.stop_id
      end)
  end

  defp rewritten_segment_end(_ref, stop_id, old, new) do
    if stop_id == old.stop_id, do: new.stop_id, else: stop_id
  end

  defp segment_drop(%{replace: :rekey_segments} = ref, row) do
    %{
      key: ref.key,
      label: ref.label,
      count: 1,
      kept: nil,
      details: [%{from_stop_id: row.from_stop_id, to_stop_id: row.to_stop_id}]
    }
  end

  defp collision?(ref, row, old, new) do
    case ref.collision_key do
      nil ->
        false

      key ->
        rewritten = Map.new(key, &{&1, rewritten_value(ref, &1, row, old, new)})

        # No prefilter on the ref's own column: `collision_filter/2` already
        # restricts the whole key, and for a deadhead column the rewritten
        # value is `stop:<id>` rather than the bare ID, so a prefilter on
        # `== new.stop_id` would match nothing.
        ref.schema
        |> where([r], field(r, :organization_id) == ^new.organization_id)
        |> where([r], field(r, :gtfs_version_id) == ^new.gtfs_version_id)
        |> exclude_self(row)
        |> collision_filter(rewritten)
        |> limit(1)
        |> Repo.exists?()
    end
  end

  # The row being tested is not a collision with itself. A `where` on the id is
  # written with `field/2` rather than `id/1` because the column is a runtime
  # value of the caller's schema, not this module's.
  defp exclude_self(query, row) do
    where(query, [r], field(r, :id) != ^row.id)
  end

  # A `nil` in a collision key is a real key value, not a missing one: the
  # transfers key carries four nullable route and trip columns, and the transfer
  # index is `NULLS NOT DISTINCT`, so a nil matches a nil. Ecto refuses
  # `field(r, ^column) == nil` outright, so nil becomes `is_nil/1` here and the
  # two forms stay distinguishable.
  defp collision_filter(query, rewritten) do
    Enum.reduce(rewritten, query, fn
      {column, nil}, query -> where(query, [r], is_nil(field(r, ^column)))
      {column, value}, query -> where(query, [r], field(r, ^column) == ^value)
    end)
  end

  # The value a column takes once the old stop's ID becomes the new one's. The
  # deadhead columns store `stop:<id>` or a bare `<id>` depending on when the
  # row was written, and the rewritten row has to keep the form it already used
  # or it would silently point at a different kind of endpoint.
  defp rewritten_value(%{via: :fk_uuid}, _column, _row, _old, new), do: new.id

  defp rewritten_value(ref, column, row, old, new) do
    stored = Map.fetch!(row, column)

    if ref.column == column and stop_reference?(stored, old) do
      reencode_stop_ref(stored, new.stop_id)
    else
      stored
    end
  end

  # Whether a stored value is a reference to the old stop, in either the bare or
  # the `stop:`-prefixed form. The row itself is not asked: a deadhead row
  # stores a `to_ref` string and carries no stop ID of its own, so the only
  # thing that knows what the value means is the stop being replaced.
  defp stop_reference?(stored, old) do
    stored == old.stop_id or stored == "stop:" <> old.stop_id
  end

  defp reencode_stop_ref("stop:" <> _id, new_stop_id), do: "stop:" <> new_stop_id
  defp reencode_stop_ref(_bare, new_stop_id), do: new_stop_id

  # The row that survives a collision: the one the replacement already has,
  # fetched so the review can show the person what they are keeping.
  defp collision_kept(ref, row, old, new) do
    key = ref.collision_key

    ref.schema
    |> where([r], field(r, :organization_id) == ^new.organization_id)
    |> where([r], field(r, :gtfs_version_id) == ^new.gtfs_version_id)
    |> exclude_self(row)
    |> collision_filter(Map.new(key, &{&1, rewritten_value(ref, &1, row, old, new)}))
    |> limit(1)
    |> Repo.one()
    |> kept_summary(ref)
  end

  defp kept_summary(nil, _ref), do: nil

  defp kept_summary(row, %{key: key}) when key in [:deadhead_from, :deadhead_to] do
    %{from_ref: row.from_ref, to_ref: row.to_ref, minutes: row.minutes}
  end

  defp kept_summary(row, _ref), do: %{id: row.id}

  # A row's own minutes for the kinds a person needs to read. A deadhead row
  # shows both ends' minutes: "5 from the garage, 20 back" is the fact that
  # decides whether the replacement is acceptable, and neither half says it.
  defp replace_details(%{key: key}, row, _new) when key in [:deadhead_from, :deadhead_to] do
    [%{from_ref: row.from_ref, to_ref: row.to_ref, minutes: row.minutes}]
  end

  defp replace_details(_ref, _row, _new), do: []

  # The rows of one kind that name the old stop, loaded whole: the collision
  # test needs the other key columns, and a per-row query would be one query
  # per row on a table with hundreds of them.
  defp replace_rows(ref, old) do
    ref
    |> StopReferences.scope_query(old)
    |> limit(^@replace_row_limit)
    |> Repo.all()
  end

  defp replace_count(ref, old) do
    ref
    |> StopReferences.scope_query(old)
    |> select([row], count(field(row, :id)))
    |> Repo.one()
  end

  # Both stops' content, not only their `updated_at`: that column is a whole
  # second (see `review_fingerprint/4`), so a stop renamed inside the same
  # second would otherwise leave the fingerprint matching a state nobody
  # reviewed. Every count is in the hash because a new reference row changes
  # what the replace would do without changing either stop.
  defp replace_fingerprint(old, new, counts, audit) do
    digest({
      {old.id, old.stop_id, old.updated_at, stop_content(old)},
      {new.id, new.stop_id, new.updated_at, stop_content(new)},
      old.location_type,
      new.location_type,
      counts,
      audit.organization_id,
      audit.gtfs_version_id
    })
  end

  @doc """
  Replaces the old stop with the new one across every reference.

  `options` carries `:fingerprint` — the one `replace_review/3` returned — and
  `:delete_old`, which removes the old stop once its references have moved.
  Every reference kind's own `replace` rule from `StopReferences.all/0` is
  applied, so this function never names a table and a new reference kind
  becomes replaceable by adding one entry to that list.

  Answers `{:ok, %{new: Stop.t(), old: Stop.t() | nil, replaced: map()}}`,
  where `replaced` reports each kind under its `report_key` as
  `%{key:, rewritten:, dropped:}` — the same names the review used, so the
  dialog and the result cannot disagree. Or one of

    * `{:error, {:refused, reasons}}` — the same refusals the review reports,
      re-derived inside the transaction rather than trusted from the caller.
    * `{:error, :stale_review}` — the fingerprint no longer matches, so a
      reference appeared or disappeared since the editor read the review.
      Nothing is written.
    * `{:error, :forbidden | :not_found | :busy | :failed_audit}` — as for
      `create_stop/2`.

  ## Order, and why a colliding row is deleted rather than skipped

  A colliding row is deleted **before** the surviving rows are rewritten.
  Updating first would put two rows on one unique key and raise inside the
  transaction, so the whole replace would roll back on exactly the input the
  review had already told the editor about — a review that promises a
  successful apply and then refuses it.

  The collision test is `collision?/4`, the review's own, so the two halves
  cannot disagree about which rows collide. That carries the review's two
  collision rules with it verbatim: a `nil` in a key column becomes `is_nil/1`,
  and there is **no** prefilter on the ref's own column, because a deadhead row
  stores `stop:<id>` rather than the bare ID. The collision keys come from the
  catalog's own `collision_key`, which is the authoritative list — including
  `fare_leg_join_rules`, whose key is easy to leave out.
  """
  @spec replace_stop(Ecto.UUID.t(), Ecto.UUID.t(), map(), AuditContext.t()) ::
          {:ok, map()}
          | {:error,
             {:refused, [atom()]}
             | :stale_review
             | :forbidden
             | :not_found
             | :busy
             | :failed_audit
             | :invalid_input}
  def replace_stop(old_uuid, new_uuid, options, %AuditContext{} = audit)
      when is_binary(old_uuid) and is_binary(new_uuid) and is_map(options) do
    run_command_transaction(fn -> commit_replace(old_uuid, new_uuid, options, audit) end)
  end

  def replace_stop(_old_uuid, _new_uuid, _options, _audit), do: {:error, :invalid_input}

  defp commit_replace(old_uuid, new_uuid, options, audit) do
    Authorization.lock_editor!(audit)
    _version = lock_published_version!(audit)

    old = lock_stop!(old_uuid, audit)
    new = lock_stop!(new_uuid, audit)

    case build_replace_review(old, new, audit) do
      {:error, {:refused, reasons}} -> Repo.rollback({:refused, reasons})
      {:ok, review} -> apply_replace_review(old, new, review, options, audit)
    end
  end

  # The review is re-derived here rather than trusted from the caller: it is
  # what proves the state still is the state that was reviewed, and the
  # fingerprint compared against it is what says so. Both stops are already
  # locked, so nothing can change under the answer between the two calls.
  defp apply_replace_review(old, new, review, options, audit) do
    counts = Enum.map(review.changes, &{&1.key, &1.count})
    expected = replace_fingerprint(old, new, counts, audit)

    if matches_fingerprint?(Map.get(options, :fingerprint), expected) do
      replaced =
        Enum.reduce(StopReferences.all(), %{}, fn ref, effects ->
          apply_replace_ref(ref, old, new, effects)
        end)

      audit_replace(old, new, replaced, options, audit)

      old = maybe_delete_old(old, options)

      %{new: new, old: old, replaced: replaced}
    else
      Repo.rollback(:stale_review)
    end
  end

  # `:delete_old` is the editor's own decision, not a rule: with it false the
  # old stop stays in the feed and simply stops being served, which is what
  # "keep it for now, merge it later" means. The audit entry is written before
  # the delete, so a stop that was removed still has the record of why.
  defp maybe_delete_old(old, options) do
    if Map.get(options, :delete_old, false) do
      case Repo.delete(old) do
        {:ok, deleted} -> deleted
        {:error, %Ecto.Changeset{} = failed} -> Repo.rollback(failed)
      end
    else
      old
    end
  end

  # `:refuse` kinds were already refused by `build_replace_review/3`; a
  # non-zero count here would mean the review and the apply disagree, which is
  # the one thing this command must not do silently.
  defp apply_replace_ref(%{replace: :refuse} = ref, old, _new, effects) do
    if replace_count(ref, old) == 0 do
      effects
    else
      Repo.rollback(:stale_review)
    end
  end

  # `:drop` — the deleted stop's own translations. Every row goes and nothing
  # takes its place.
  defp apply_replace_ref(%{replace: :drop} = ref, old, _new, effects) do
    {count, _rows} = Repo.delete_all(StopReferences.scope_query(ref, old))
    put_effect(effects, ref, count, 0)
  end

  # `:rewrite` — one statement for the whole kind. Stop times and pattern
  # occurrences are the kinds with thousands of rows, and neither can collide:
  # no unique index of theirs carries the rewritten column.
  defp apply_replace_ref(%{replace: :rewrite} = ref, old, new, effects) do
    {count, _rows} =
      Repo.update_all(StopReferences.scope_query(ref, old),
        set: [{ref.column, replacement_value(ref, new)}]
      )

    put_effect(effects, ref, count, 0)
  end

  # `:rewrite_dedupe_array` — `flex_services.hub_stop_ids`. The element is
  # replaced and the array deduped, so a service that already hubs the
  # replacement does not end up naming it twice.
  defp apply_replace_ref(%{replace: :rewrite_dedupe_array} = ref, old, new, effects) do
    count =
      Enum.reduce(replace_all_rows(ref, old), 0, fn row, count ->
        if rewrite_hubs(ref, row, old, new), do: count + 1, else: count
      end)

    put_effect(effects, ref, count, 0)
  end

  # `:rewrite_keep_existing` — rewrite the row, unless the rewritten key lands
  # on a row the replacement already has, in which case the replacement's row
  # is kept and the old one deleted. The deletes run first, so the rewrite that
  # follows cannot briefly put two rows on one unique key.
  defp apply_replace_ref(%{replace: :rewrite_keep_existing} = ref, old, new, effects) do
    rows = replace_all_rows(ref, old)
    {colliding, surviving} = Enum.split_with(rows, &collision?(ref, &1, old, new))

    dropped = delete_rows(colliding)

    rewritten =
      Enum.reduce(surviving, 0, fn row, count ->
        update_row(ref, row, %{ref.column => rewritten_value(ref, ref.column, row, old, new)})
        count + 1
      end)

    put_effect(effects, ref, rewritten + dropped, dropped)
  end

  # `:rekey_segments` — re-point both ends of a shared map-line section, and
  # drop the row when it would collide or become `(new, new)`. A zero-length
  # line draws as real service between a stop and itself, which is why the
  # review drops it and the apply has to agree.
  defp apply_replace_ref(%{replace: :rekey_segments} = ref, old, new, effects) do
    {colliding, surviving} =
      replace_all_rows(ref, old)
      |> Enum.split_with(fn row ->
        pair = rekeyed_segment(row, old, new)
        rekeyed_self_pair?(pair, new) or collision?(ref, row, old, new)
      end)

    dropped = delete_rows(colliding)

    rewritten =
      Enum.reduce(surviving, 0, fn row, count ->
        update_row(ref, row, rekeyed_segment(row, old, new))
        count + 1
      end)

    put_effect(effects, ref, rewritten + dropped, dropped)
  end

  defp rewrite_hubs(%{column: column} = ref, row, old, new) do
    stored = Map.fetch!(row, column)

    hubs =
      stored
      |> Enum.map(fn stop_id -> if stop_id == old.stop_id, do: new.stop_id, else: stop_id end)
      |> Enum.uniq()

    if hubs == stored do
      false
    else
      update_row(ref, row, %{column => hubs})
      true
    end
  end

  defp rekeyed_segment(row, old, new) do
    %{
      from_stop_id: rewritten_segment_end(nil, row.from_stop_id, old, new),
      to_stop_id: rewritten_segment_end(nil, row.to_stop_id, old, new)
    }
  end

  # The apply's own copy of the review's `(new, new)` rule, asked of the pair
  # this replace actually writes rather than of the stored one.
  defp rekeyed_self_pair?(pair, new) do
    pair.from_stop_id == new.stop_id and pair.to_stop_id == new.stop_id
  end

  # A `via: :fk_uuid` entry names `stops.id`; every other entry names the GTFS ID.
  # No `:rewrite` entry is currently `:fk_uuid`, but the value is read off the
  # entry rather than assumed so a future one cannot write a stop UUID into a
  # string column.
  defp replacement_value(%{via: :fk_uuid}, new), do: new.id
  defp replacement_value(_ref, new), do: new.stop_id

  # The rows are loaded whole rather than through `replace_rows/2`'s display
  # cap: the cap bounds what a dialog shows, and applying only the first 5,000
  # would leave the rest of the feed naming a stop that was replaced. Only the
  # kinds whose rewritten key can collide are loaded row by row; `:rewrite` is
  # one statement whatever the count.
  defp replace_all_rows(ref, old), do: Repo.all(StopReferences.scope_query(ref, old))

  defp delete_rows([]), do: 0

  defp delete_rows(rows) do
    Enum.each(rows, fn row ->
      case Repo.delete(row) do
        {:ok, _deleted} -> :ok
        {:error, %Ecto.Changeset{} = failed} -> Repo.rollback(failed)
      end
    end)

    length(rows)
  end

  defp update_row(%{schema: schema}, row, changes) do
    {1, _rows} =
      schema
      |> where([r], field(r, :id) == ^row.id)
      |> Repo.update_all(set: Enum.map(changes, fn {column, value} -> {column, value} end))

    :ok
  end

  # One entry per name the review used, and only for a kind that actually
  # changed: a replace that touched nothing reports nothing rather than a list
  # of zeros a dialog would have to filter before it could say anything.
  # `transfers_from` and `transfers_to` are
  # the same table and report as one `:transfers`, and their counts add — a
  # dialog that said "1 transfer" for a row seen from both ends would be wrong.
  defp put_effect(effects, _ref, 0, 0), do: effects

  defp put_effect(effects, ref, rewritten, dropped) do
    key = StopReferences.report_key(ref)

    Map.update(
      effects,
      key,
      %{key: key, rewritten: rewritten, dropped: dropped},
      fn effect ->
        %{
          effect
          | rewritten: effect.rewritten + rewritten,
            dropped: effect.dropped + dropped
        }
      end
    )
  end

  # What the history entry records: which stop took over, whether the old one
  # was removed, and every kind that moved. The counts are the ones the editor
  # agreed to, so the audit and the dialog say the same numbers.
  defp audit_replace(old, new, replaced, options, audit) do
    attrs = %{
      "replaced_by" => new.stop_id,
      "delete_old" => Map.get(options, :delete_old, false),
      "replaced" =>
        replaced
        |> Enum.map(fn {key, effect} -> {key, effect.rewritten} end)
        |> Map.new()
    }

    audit!(old, audit, "updated", attrs)
  end

  @doc """
  Makes a stop the first bay of a new station.

  The stop keeps its own GTFS ID and everything that names it — its stop times,
  its transfers, its place in every pattern. A station is created beside it at
  the same coordinates, and the stop is re-parented onto that station. Nothing
  that referenced the stop is rewritten, which is the whole reason the operation
  is safe to offer on a stop that is already in service.

  `attrs` carries `station_name` and `platform_code`. The station's ID comes from
  `Stop.generate_stop_id/2` and is made unique by `Gtfs.unique_stop_id/4`, so two
  stations with the same name get two IDs rather than one overwriting the other.

  Answers `{:ok, %{station: Stop.t(), stop: Stop.t()}}`, or

    * `{:error, :child}` — the stop is already a bay. Nesting a bay in a station
      is not something GTFS means, and the editor that offered this did not know
      about the parent.
    * `{:error, :has_children}` — the stop already has bays. It is a station
      already, however it was recorded, and this is not the command that changes
      one station into another.
    * `{:error, :forbidden | :not_found | :busy | :failed_audit | :invalid_station}` —
      as for `create_stop/2`, plus a station name that yields no ID.

  Both stops are written in one transaction with both audit entries: a
  bay whose station was rolled back would be a bay naming nothing.
  """
  @spec make_station(Ecto.UUID.t(), map(), AuditContext.t()) ::
          {:ok, %{station: Stop.t(), stop: Stop.t()}}
          | {:error,
             :child
             | :has_children
             | :invalid_station
             | :forbidden
             | :not_found
             | :busy
             | :failed_audit
             | Ecto.Changeset.t()}
  def make_station(stop_uuid, attrs, %AuditContext{} = audit)
      when is_binary(stop_uuid) and is_map(attrs) do
    run_command_transaction(fn -> commit_make_station(stop_uuid, attrs, audit) end)
  end

  def make_station(_stop_uuid, _attrs, _audit), do: {:error, :invalid_input}

  defp commit_make_station(stop_uuid, attrs, audit) do
    Authorization.lock_editor!(audit)
    _version = lock_published_version!(audit)

    stop = lock_stop!(stop_uuid, audit)

    with :ok <- refuse_unstationable(stop) do
      station = insert_station(stop, attrs, audit)
      bay = reparent_stop(stop, attrs, station, audit)

      %{station: station, stop: bay}
    end
  end

  # Both refusals are asked of the stop itself. A bay already has a parent, and a
  # stop with children is a station whether or not its `location_type` says so —
  # which is exactly the state a partially imported feed leaves behind.
  defp refuse_unstationable(stop) do
    cond do
      is_binary(stop.parent_station) and stop.parent_station != "" ->
        Repo.rollback(:child)

      child_stop_count(stop) > 0 ->
        Repo.rollback(:has_children)

      true ->
        :ok
    end
  end

  defp child_stop_count(stop) do
    Stop
    |> where(
      [s],
      s.parent_station == ^stop.stop_id and s.organization_id == ^stop.organization_id and
        s.gtfs_version_id == ^stop.gtfs_version_id
    )
    |> Repo.aggregate(:count, :id)
  end

  defp insert_station(stop, attrs, audit) do
    attrs = stringify_keys(attrs)
    name = attrs["station_name"]
    base = Stop.generate_stop_id(1, name)

    if base == "" do
      Repo.rollback(:invalid_station)
    else
      station_id =
        Gtfs.unique_stop_id(audit.organization_id, audit.gtfs_version_id, base)

      # The station is placed where the stop is: an editor turning one stop into
      # a station is describing the place it already is, not moving it.
      station_attrs = %{
        "stop_id" => station_id,
        "stop_name" => name,
        "location_type" => 1,
        "stop_lat" => stop.stop_lat,
        "stop_lon" => stop.stop_lon,
        "organization_id" => audit.organization_id,
        "gtfs_version_id" => audit.gtfs_version_id
      }

      insert_station_row(station_attrs, name, audit)
    end
  end

  defp insert_station_row(station_attrs, name, audit) do
    # Ownership is never cast from the attributes: since #736 the audit context
    # is the only source, so the station's organization and version come from the
    # command's caller and not from the map this function was handed.
    attrs = Map.drop(station_attrs, ["organization_id", "gtfs_version_id"])

    case Stop.create_changeset(%Stop{}, attrs, audit) do
      %Ecto.Changeset{valid?: true} = changeset ->
        case Repo.insert(changeset) do
          {:ok, station} ->
            audit!(station, audit, "created", %{"stop_name" => name})
            station

          {:error, %Ecto.Changeset{} = failed} ->
            Repo.rollback(failed)
        end

      failed ->
        Repo.rollback(failed)
    end
  end

  # The bay is renamed to say where it is — "Newport City Hall, Bay A" — so a
  # rider reading a stop list sees the station rather than a bare code. Its ID
  # and every reference to it are untouched, which is the difference between
  # this and a replace.
  defp reparent_stop(stop, attrs, station, audit) do
    attrs = stringify_keys(attrs)
    name = attrs["station_name"]
    platform_code = attrs["platform_code"]

    bay_attrs = %{
      "parent_station" => station.stop_id,
      "platform_code" => platform_code,
      "stop_name" => bay_name(name, platform_code)
    }

    case Stop.editor_changeset(stop, bay_attrs) do
      %Ecto.Changeset{valid?: true} = changeset ->
        case Repo.update(changeset) do
          {:ok, bay} ->
            audit!(stop, audit, "updated", bay_attrs)
            bay

          {:error, %Ecto.Changeset{} = failed} ->
            Repo.rollback(failed)
        end

      failed ->
        Repo.rollback(failed)
    end
  end

  defp bay_name(name, nil), do: name
  defp bay_name(name, ""), do: name
  defp bay_name(name, platform_code), do: "#{name}, Bay #{platform_code}"

  @doc """
  Creates a stop in a version, audited in the same transaction.

  `attrs` is the editor's draft. A blank or absent `stop_id` is filled by the
  version's ID rule; anything the editor typed is kept as typed.
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
    Authorization.lock_editor!(audit)
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
    |> Stop.create_changeset(attrs, audit)
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

  @doc """
  The most recent audit entry for one stop, or `nil` when it has never been saved.

  This is the other half of a stale save: `update_stop/4` refuses the write and
  says the row moved on, and this says who moved it and what they changed. The
  panel needs both, because "someone else saved this stop" without a name is a
  dead end an editor cannot act on.

  Scoped by organization and version and bound to the stop's UUID, so a deleted
  and recreated natural ID never inherits the old attribution — the same reason
  the route command's history view binds to `route.id`.
  """
  @spec last_change(Ecto.UUID.t(), Ecto.UUID.t(), Ecto.UUID.t() | nil) :: map() | nil
  def last_change(_organization_id, _gtfs_version_id, nil), do: nil

  def last_change(organization_id, gtfs_version_id, stop_uuid)
      when is_binary(stop_uuid) do
    if uuid?(stop_uuid) do
      from(log in ChangeLog,
        where:
          log.organization_id == ^organization_id and
            log.gtfs_version_id == ^gtfs_version_id and
            log.entity_type == "stop" and log.entity_id == ^stop_uuid,
        order_by: [desc: log.inserted_at, desc: log.id],
        limit: 1,
        select: %{actor_email: log.actor_email, changed_fields: log.changed_fields}
      )
      |> Repo.one()
    else
      nil
    end
  end

  def last_change(_organization_id, _gtfs_version_id, _stop_uuid), do: nil

  # Mutation and audit commit together. An unrecordable audit rolls the
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
