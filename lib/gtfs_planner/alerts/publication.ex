defmodule GtfsPlanner.Alerts.Publication do
  @moduledoc """
  One alert's public intent, stored in `alert_publications`.

  A row exists only after an editor explicitly accepted a revision for
  publication, and it belongs to the same organization as its alert through the
  composite `alert_publications_alert_owner_fkey`. It keeps the newest desired
  intent and the last content a served manifest actually included, which is what
  makes the difference between "asked for" and "published" observable; it is not
  a public history, so one alert has exactly one row for its organization.

  Every field is server-owned. The actor and the timestamps record who asked and
  when, so an audit value outlives a user the organization later removes, and no
  client, form param or prepared assistant change writes this row: the `Alerts`
  commands of the accepted-content step own `desired_revision`,
  `desired_snapshot`, `confirmed_revision`, `confirmed_snapshot` and
  `withdrawal`, and the serving steps own `last_published_at` from an observed
  receipt.
  """

  use Ecto.Schema

  import Ecto.Query, warn: false

  alias GtfsPlanner.Alerts.Alert
  alias GtfsPlanner.Alerts.Feed
  alias GtfsPlanner.FeedPublishing.Publication, as: Channel
  alias GtfsPlanner.Repo

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  # The header timestamp a pre-acceptance measurement encodes with. Every
  # snapshot in the envelope has its periods opened before it is measured, so
  # this instant cannot drop an entity for having ended and cannot exclude a
  # scheduled one for not having been noticed yet: the measurement is an upper
  # bound on every projection the feed can ever produce, not the projection.
  @max_header_instant 253_402_300_799

  @type field_error :: %{
          field: atom(),
          message: String.t(),
          key: String.t() | nil,
          choices: [map()]
        }

  # `none` is a draft with no removal requested. `pending` is a confirmed removal
  # the served manifest has not applied yet, so a disable/delete/re-enable cycle
  # cannot resurrect the alert while a refresh is still owed.
  @withdrawals [:none, :pending]

  schema "alert_publications" do
    field :desired_revision, :integer
    field :desired_snapshot, :map
    field :confirmed_revision, :integer
    field :confirmed_snapshot, :map
    field :requested_by_id, Ecto.UUID
    field :requested_at, :utc_datetime_usec
    field :last_published_at, :utc_datetime_usec
    field :withdrawal, Ecto.Enum, values: @withdrawals, default: :none

    belongs_to :organization, GtfsPlanner.Organizations.Organization
    belongs_to :alert, Alert

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          organization_id: Ecto.UUID.t() | nil,
          alert_id: Ecto.UUID.t() | nil,
          desired_revision: integer() | nil,
          desired_snapshot: map() | nil,
          confirmed_revision: integer() | nil,
          confirmed_snapshot: map() | nil,
          requested_by_id: Ecto.UUID.t() | nil,
          requested_at: DateTime.t() | nil,
          last_published_at: DateTime.t() | nil,
          withdrawal: :none | :pending | nil,
          organization:
            GtfsPlanner.Organizations.Organization.t() | Ecto.Association.NotLoaded.t(),
          alert: Alert.t() | Ecto.Association.NotLoaded.t(),
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @doc """
  Lists the stored withdrawal states.

  `none` and `pending` are the two values the table's own check constraint
  accepts; the states a served manifest reaches from them are derived from the
  confirmed snapshot and the receipts, never stored here.
  """
  @spec withdrawals() :: [atom()]
  def withdrawals, do: @withdrawals

  @doc """
  Reads the alert's trusted capture as the scope an accepted snapshot carries.

  The capture is the only source here: no row UUID is resolved and no live row
  is read, so an alert whose source version has been deleted still publishes the
  identities it was accepted with. A `mode_route_type` answer is *not* a GTFS
  identity, so the caller passes the explicit route ids the trusted source holds
  for that mode (`mode_route_ids`); an answer that named both a mode and routes
  prefers the routes it actually selected.

  Every unresolved identity refuses. A selector that no longer resolves is
  Needs attention, never something to publish as a narrower or guessed alert
  (`selector_source_required`, the same reason `Alerts.Feed` refuses).
  """
  @spec scope_from_reference(map() | nil, [String.t()]) ::
          {:ok, Feed.scope()} | {:error, [field_error()]}
  def scope_from_reference(reference, mode_route_ids \\ [])
      when is_list(mode_route_ids) do
    selectors = reference_selectors(reference)

    with :ok <- refuse_unresolved(selectors) do
      {:ok,
       %{
         shape: feed_shape(selectors["shape"]),
         direction_id: direction_id(selectors["direction_id"]),
         agencies: gtfs_ids(selectors["agencies"]),
         routes: route_ids(selectors, mode_route_ids),
         stops: gtfs_ids(selectors["stops"]),
         route_stops: route_stops(selectors["route_stops"]),
         trips: trips(selectors["trips"])
       }}
    end
  end

  @doc """
  Builds one accepted snapshot: the whole public intent of one alert, reduced to
  GTFS identities and absolute instants.

  This is a pure assembly of values the caller already resolved and compiled.
  Nothing is defaulted here: a missing public identity, an unusable scope or a
  structurally invalid snapshot is refused by `Alerts.Feed` at the admission
  measurement below, so a value that cannot be represented exactly is never
  published narrowed.
  """
  @spec snapshot(Alert.t(), map(), Feed.scope()) :: map()
  def snapshot(%Alert{} = alert, compiled, scope) when is_map(compiled) and is_map(scope) do
    %{
      public_entity_id: to_string(alert.public_entity_id),
      accepted_revision: alert.revision,
      notice_at: compiled.notice_at,
      periods: compiled.periods,
      effect: alert.effect,
      cause: alert.cause,
      cause_detail: alert.cause_detail,
      header: message_text(alert, :header),
      description: message_text(alert, :description),
      url: message_text(alert, :url),
      scope: scope
    }
  end

  @doc """
  Reads one stored `desired_snapshot` back into the shape `Alerts.Feed` encodes.

  The column is `jsonb`, so a snapshot that was written with atom keys, real
  `Date` structs and atom effects comes back with string keys, ISO dates and
  effect text. Decoding is therefore not optional for anything that reads
  accepted content: both the admission measurement below and the refresh that
  serves it go through here, so the bytes a stored snapshot measures are the
  bytes it would actually publish.

  A value outside the stored vocabulary decodes to nil rather than to an atom
  nobody named, which the encoder refuses instead of publishing a default.
  """
  @spec snapshot_from_stored(map()) :: Feed.snapshot()
  def snapshot_from_stored(snapshot) when is_map(snapshot) do
    snapshot |> decode() |> Map.put_new(:periods, [])
  end

  @doc """
  Decides whether one organization's accepted content still fits the budget
  once `candidate` replaces this alert's own previous intent.

  The envelope is every non-withdrawn desired snapshot of the organization —
  including the scheduled ones, whose notice has not begun — with each one's
  periods opened so the measurement cannot drop an entity that a later
  projection would still include. Encoding that envelope at the maximum header
  timestamp therefore bounds every future projection of this organization's
  feed, which is what makes a notice boundary unable to newly exceed the
  accepted envelope.

  Both representations are measured, because the JSON is roughly two to three
  times the protobuf for this message. Nothing is ever truncated: an
  organization over budget is refused, and its earlier accepted intent is left
  exactly as it was so a corrective removal remains possible.

  A stored snapshot that cannot be encoded at all - legacy or corrupt accepted
  data - refuses the same way, naming that the accepted item has to be removed.
  Delivery is blocked visibly rather than silently narrowed, and `Alerts`
  continues to allow the removal.
  """
  @spec admit(Ecto.UUID.t(), Ecto.UUID.t(), map()) :: :ok | {:error, [field_error()]}
  def admit(organization_id, alert_id, candidate) do
    organization_id
    |> accepted_snapshots_except(alert_id)
    |> Kernel.++([candidate])
    |> envelope()
    |> Feed.encode(@max_header_instant)
    |> case do
      {:ok, _encoded} ->
        :ok

      {:error, :too_large} ->
        {:error, [error(:publication, budget_message(organization_id))]}

      {:error, :selector_source_required} ->
        {:error,
         [
           error(
             :publication,
             "Another accepted alert names an identity its source no longer has. " <>
               "Remove that alert to publish."
           )
         ]}

      {:error, _invalid} ->
        {:error,
         [
           error(
             :publication,
             "Another accepted alert cannot be published as it is stored. " <>
               "Remove that alert to publish."
           )
         ]}
    end
  end

  @doc """
  Records one accepted revision as this alert's newest desired public intent.

  The newest desired intent replaces the previous one rather than appending to
  it, so the table stays one row per alert. `confirmed_revision`,
  `confirmed_snapshot` and `last_published_at` are left untouched: they are
  receipts observed from a served manifest, and only the delivery steps may move
  them, so an accepted revision never claims to have been published.
  """
  @spec accept(Alert.t(), map(), Ecto.UUID.t()) :: {:ok, t()} | {:error, Ecto.Changeset.t()}
  def accept(%Alert{} = alert, snapshot, actor_id) do
    desired = %{
      desired_revision: alert.revision,
      desired_snapshot: snapshot,
      requested_by_id: actor_id,
      requested_at: DateTime.utc_now(),
      withdrawal: :none
    }

    case scoped_row(alert) do
      %__MODULE__{} = existing ->
        write(existing, desired)

      nil ->
        write(%__MODULE__{organization_id: alert.organization_id, alert_id: alert.id}, desired)
    end
  end

  @doc """
  Records the confirmed removal of an alert that has accepted public history.

  The desired snapshot is kept rather than cleared, because it is what a served
  manifest is still serving and what a re-enable has to reconcile against. Only
  the withdrawal intent changes here, and it survives disabling: nothing in
  this function reads configuration, so a disabled organization still retains
  its tombstone and its pending removal.
  """
  @spec withdraw(Alert.t()) :: {:ok, t()} | {:error, Ecto.Changeset.t()}
  def withdraw(%Alert{} = alert) do
    case scoped_row(alert) do
      %__MODULE__{} = existing -> write(existing, %{withdrawal: :pending})
      nil -> {:error, no_publication_changeset(alert)}
    end
  end

  @doc """
  Lists the organization's removals a served manifest has not applied yet.

  A removed alert is excluded from the editor's own listing, so this is the one
  read that keeps a pending removal observable outside the deleted row.
  """
  @spec pending_removals(Ecto.UUID.t()) :: [t()]
  def pending_removals(organization_id) do
    Repo.all(
      from(publication in __MODULE__,
        join: alert in Alert,
        on: alert.id == publication.alert_id,
        where: publication.organization_id == ^organization_id,
        where: publication.withdrawal == :pending,
        order_by: [asc: alert.last_date, asc: alert.id],
        select: %{
          id: publication.id,
          alert_id: alert.id,
          organization_id: publication.organization_id,
          desired_revision: publication.desired_revision,
          confirmed_revision: publication.confirmed_revision,
          last_published_at: publication.last_published_at,
          header: fragment("?->>'header'", alert.message),
          withdrawn_at: alert.deleted_at
        }
      )
    )
  end

  @doc """
  Locks this organization's channel row for the rest of an interactive write.

  Returns nil when the channel has no state yet - an organization that has
  never claimed a namespace has nothing to dirty - and the caller records the
  intent anyway, because `alert_publications` is the durable record and the
  channel's `desired_revision` is only the wake signal.

  Call only inside `Repo.transaction/1`, and only after
  `Authorization.lock_editor!/1`: the spec's lock order is membership, then
  channel, then the alert rows.
  """
  @spec lock_channel!(Ecto.UUID.t()) :: Channel.t() | nil
  def lock_channel!(organization_id) do
    case Ecto.UUID.cast(organization_id) do
      {:ok, id} ->
        Repo.one(
          from(publication in Channel,
            where: publication.organization_id == ^id and publication.channel == :alerts,
            lock: "FOR UPDATE"
          )
        )

      :error ->
        nil
    end
  end

  @doc """
  Marks the locked alerts channel dirty, so a periodic refresh notices the new
  intent without a browser being connected.

  Only `desired_revision` moves. The channel's stored status, receipts and
  attempt history belong to the delivery steps, so acceptance never claims that
  a payload was staged, switched or published.
  """
  @spec mark_channel_dirty!(Channel.t() | nil) :: :ok
  def mark_channel_dirty!(nil), do: :ok

  def mark_channel_dirty!(%Channel{} = channel) do
    # The change is stated as a field/value pair rather than by rebuilding the
    # struct: `Ecto.Changeset.change/1` compares the struct against itself and
    # would produce a changeset with no changes at all, which `Repo.update/2`
    # answers without ever issuing an `UPDATE`.
    channel
    |> Ecto.Changeset.change(desired_revision: channel.desired_revision + 1)
    |> Repo.update!()

    :ok
  end

  @doc """
  The field error shape every refusal in this context reports.

  `GtfsPlanner.Alerts.FeedPeriods` owns the shape (a field, a message, an
  optional ambiguous-reading key and the choices for it), so an editor renders
  a DST correction and an over-budget acceptance the same way.
  """
  @spec error(atom(), String.t()) :: field_error()
  def error(field, message),
    do: %{field: field, message: message, key: nil, choices: []}

  # -- Snapshot assembly ----------------------------------------------------

  defp reference_selectors(reference) when is_map(reference),
    do: Map.get(reference, "selectors") || %{}

  defp reference_selectors(_reference), do: %{}

  # An identity the version no longer holds is recorded as unresolved by the
  # capture, and publishing around it would widen or narrow the alert. Refusing
  # is the one answer that cannot misinform a rider.
  defp refuse_unresolved(selectors) do
    unresolved =
      [selectors["unresolved_routes"], selectors["unresolved_stops"]] ++
        unresolved_pairs(selectors["route_stops"]) ++
        unresolved_trips(selectors["trips"])

    case Enum.reject(unresolved, &(&1 in [nil, []])) do
      [] -> :ok
      _present -> {:error, [error(:scope, unresolved_message())]}
    end
  end

  defp unresolved_pairs(nil), do: []

  defp unresolved_pairs(pairs) when is_list(pairs),
    do: Enum.reject(pairs, & &1["resolved"])

  defp unresolved_pairs(_pairs), do: [[true]]

  defp unresolved_trips(nil), do: []

  defp unresolved_trips(trips) when is_list(trips),
    do: Enum.reject(trips, & &1["resolved"])

  defp unresolved_trips(_trips), do: [[true]]

  defp unresolved_message do
    "This alert names an identity its source no longer has. Retarget it before publishing."
  end

  # A mode is expanded by the caller into the explicit routes the trusted source
  # holds for it. An empty expansion leaves the routes empty, which
  # `Alerts.Feed` refuses as `selector_source_required` rather than publishing a
  # guessed `route_type`.
  defp route_ids(selectors, mode_route_ids) do
    case gtfs_ids(selectors["routes"]) do
      [] -> Enum.map(mode_route_ids, &String.trim/1)
      routes -> routes
    end
  end

  defp gtfs_ids(nil), do: []

  defp gtfs_ids(entries) when is_list(entries),
    do: entries |> Enum.map(&Map.get(&1, "gtfs_id")) |> Enum.reject(&(is_nil(&1) or &1 == ""))

  defp gtfs_ids(_entries), do: []

  defp route_stops(nil), do: []

  defp route_stops(pairs) when is_list(pairs) do
    Enum.map(pairs, fn pair ->
      %{route_id: pair["route_gtfs_id"], stop_id: pair["stop_gtfs_id"]}
    end)
  end

  defp route_stops(_pairs), do: []

  defp trips(nil), do: []

  defp trips(entries) when is_list(entries) do
    Enum.map(entries, fn entry ->
      %{
        trip_id: entry["gtfs_id"],
        start_date: entry["service_date"] && Date.from_iso8601(entry["service_date"]),
        start_time: entry["start_time"]
      }
    end)
  end

  defp trips(_entries), do: []

  # `:route_direction` is a route selection that also narrows by direction, so it
  # reaches the feed as the `:routes` shape carrying that direction. An unknown or
  # absent shape stays absent, which the encoder refuses.
  defp feed_shape("system"), do: :system
  defp feed_shape("routes"), do: :routes
  defp feed_shape("route_direction"), do: :routes
  defp feed_shape("stop_all_routes"), do: :stop_all_routes
  defp feed_shape("route_stops"), do: :route_stops
  defp feed_shape("trips"), do: :trips
  defp feed_shape(_shape), do: nil

  defp direction_id(direction_id) when direction_id in [0, 1], do: direction_id
  defp direction_id(_direction_id), do: nil

  defp message_text(%Alert{message: %_{} = message}, field) do
    case Map.get(message, field) do
      text when is_binary(text) -> text
      _absent -> nil
    end
  end

  defp message_text(_alert, _field), do: nil

  # -- Admission ------------------------------------------------------------

  defp accepted_snapshots_except(organization_id, alert_id) do
    Repo.all(
      from(publication in __MODULE__,
        where: publication.organization_id == ^organization_id,
        where: publication.alert_id != ^alert_id,
        where: publication.withdrawal == :none,
        where: not is_nil(publication.desired_snapshot),
        # A stable order keeps the measurement reproducible for one input.
        order_by: [asc: publication.alert_id],
        select: publication.desired_snapshot
      )
    )
  end

  # Opening every period is what makes the measurement conservative: no entity
  # can drop out for having ended, and `Alerts.Feed` still refuses anything it
  # cannot represent, so the bound never hides an invalid snapshot either.
  #
  # A stored snapshot comes back from its `jsonb` column with string keys and
  # ISO dates, while the candidate the caller just built has atom keys and real
  # `Date` structs, so both are decoded to the one shape `Feed.encode/2` reads.
  defp envelope(snapshots), do: Enum.map(snapshots, &opening/1)

  defp opening(snapshot) when is_map(snapshot) do
    decoded = decode(snapshot)

    Map.put(decoded, :periods, Enum.map(decoded.periods, &%{start: &1.start, end: nil}))
  end

  defp opening(snapshot), do: snapshot

  defp decode(snapshot) do
    %{}
    |> put_decoded(snapshot, :public_entity_id)
    |> put_decoded(snapshot, :accepted_revision)
    |> put_decoded(snapshot, :notice_at)
    |> put_decoded(snapshot, :periods, &decode_periods/1)
    |> put_decoded(snapshot, :effect, &decode_atom/1)
    |> put_decoded(snapshot, :cause, &decode_atom/1)
    |> put_decoded(snapshot, :cause_detail)
    |> put_decoded(snapshot, :header)
    |> put_decoded(snapshot, :description)
    |> put_decoded(snapshot, :url)
    |> put_decoded(snapshot, :scope, &decode_scope/1)
    |> Map.put_new(:periods, [])
  end

  defp put_decoded(acc, snapshot, key, transform \\ & &1) do
    case fetch(snapshot, key) do
      {:ok, value} -> Map.put(acc, key, transform.(value))
      :error -> acc
    end
  end

  # The key is whichever spelling this map uses, so the same decoder accepts the
  # candidate's atom keys and a stored snapshot's string keys.
  defp fetch(snapshot, key) do
    atom = Atom.to_string(key)

    case Map.fetch(snapshot, key) do
      {:ok, value} -> {:ok, value}
      :error -> Map.fetch(snapshot, atom)
    end
  end

  defp decode_periods(periods) when is_list(periods) do
    Enum.map(periods, fn period ->
      %{start: fetch!(period, :start), end: fetch(period, :end) |> ok()}
    end)
  end

  defp decode_periods(_periods), do: []

  defp decode_scope(scope) when is_map(scope) do
    %{}
    |> put_decoded(scope, :shape, &decode_atom/1)
    |> put_decoded(scope, :direction_id)
    |> put_decoded(scope, :agencies, &List.wrap/1)
    |> put_decoded(scope, :routes, &List.wrap/1)
    |> put_decoded(scope, :stops, &List.wrap/1)
    |> put_decoded(scope, :route_stops, &decode_pairs/1)
    |> put_decoded(scope, :trips, &decode_trips/1)
  end

  defp decode_scope(_scope), do: %{}

  defp decode_pairs(pairs) when is_list(pairs) do
    Enum.map(pairs, fn pair ->
      %{route_id: fetch!(pair, :route_id), stop_id: fetch!(pair, :stop_id)}
    end)
  end

  defp decode_pairs(_pairs), do: []

  defp decode_trips(trips) when is_list(trips) do
    Enum.map(trips, fn trip ->
      %{
        trip_id: fetch!(trip, :trip_id),
        start_date: decode_date(fetch(trip, :start_date)),
        start_time: fetch(trip, :start_time) |> ok()
      }
    end)
  end

  defp decode_trips(_trips), do: []

  defp decode_date(%Date{} = date), do: date

  defp decode_date(value) when is_binary(value), do: Date.from_iso8601(value)

  defp decode_date(_value), do: nil

  # An effect and a cause are stored as the atom's own text, and only a name the
  # vocabulary still holds becomes an atom again. An unrecognized value stays a
  # string, which `Alerts.Feed` refuses rather than publishing as a default.
  defp decode_atom(value) when is_atom(value), do: value

  defp decode_atom(value) when is_binary(value) do
    Enum.find(
      Alert.effects() ++
        Alert.causes() ++
        [:system, :routes, :route_direction, :stop_all_routes, :route_stops, :trips],
      &(Atom.to_string(&1) == value)
    )
  end

  defp decode_atom(_value), do: nil

  defp fetch!(map, key) do
    case fetch(map, key) do
      {:ok, value} -> value
      :error -> nil
    end
  end

  defp ok({:ok, value}), do: value
  defp ok(:error), do: nil

  defp budget_message(_organization_id) do
    "Publishing this alert would push the accepted alerts over the " <>
      "#{div(Feed.max_bytes(), 1024 * 1024)} MiB budget. " <>
      "Remove an accepted alert, or shorten this one, and try again."
  end

  # -- Durable writes -------------------------------------------------------

  defp scoped_row(%Alert{organization_id: organization_id, id: alert_id}) do
    Repo.one(
      from(publication in __MODULE__,
        where: publication.organization_id == ^organization_id,
        where: publication.alert_id == ^alert_id,
        lock: "FOR UPDATE"
      )
    )
  end

  # One write for both cases rather than an insert and an update: the row's
  # identity is either the one already stored or the alert's own, and the
  # differences are the fields themselves.
  defp write(%__MODULE__{} = publication, desired) do
    publication
    |> Ecto.Changeset.change(desired)
    |> Repo.insert_or_update()
  end

  # Withdrawing an alert that has no publication row is a programming error
  # rather than a user error, and the caller checks for the row first.
  defp no_publication_changeset(%Alert{}) do
    Ecto.Changeset.change(%__MODULE__{})
    |> Ecto.Changeset.add_error(:alert_id, "has no accepted public intent")
  end
end
