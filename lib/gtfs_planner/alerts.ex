defmodule GtfsPlanner.Alerts do
  @moduledoc """
  The only path that writes `service_alerts` rows (INV-1).

  Every command takes the `GtfsPlanner.Gtfs.AuditContext` the LiveView already
  holds, so organization, version and actor come from trusted server context and
  are never cast from a form param (R1, R4). `Alert.draft_changeset/2` casts
  only the operator's own answers, and the fields this module owns -
  `revision`, `effect`, `complete`, `first_date`, `last_date`, `updated_by_id`
  and the timing `time_zone` - are set here or, on create, taken from the
  version's agency.

  Each alert write runs in one transaction that resolves the actor's *current*
  active membership and holds it `FOR SHARE` before the alert row is locked. A
  revocation that commits while a save is waiting for that lock therefore refuses
  the save instead of letting it commit (R5). The alert itself is then loaded
  `FOR UPDATE` scoped by organization, so a forged UUID from another tenant is
  `:not_found` rather than a leak (R6).

  The organization's active schedule is part of that lock order. Create, save and
  retarget call `Versions.lock_schedule_for_write!/2` first: the organization row
  `FOR SHARE`, the membership, then the active version `FOR UPDATE`, before the
  alerts channel and the alert row. Taking the membership first would deadlock
  with a membership command, which holds the organization row while it waits for
  the member's row. Every one of those locks is taken before the command learns
  whether it is metadata-only, so a rename or deletion of a selected target
  commits either before the validation reads it or after the alert is stored,
  never between the two. A caller passes the `expected_schedule` token it read
  with the values it is proposing; the token is an expectation, never authority,
  and a stale or forged one is refused with `{:error, :stale_active}` (an A to B
  to A return included). Creation, a changed target selection, `retarget/5` and a
  checked publication also need an active schedule (`{:error,
  :no_active_schedule}`) and validate against it, not against the version the
  navigation shows. A save that changes no target selection, and `delete_alert/3`,
  need neither.

  An alert belongs to the organization, not to the version it was written
  against. `source_gtfs_version_id` is provenance that a source deletion clears
  and that `get_alert/2`, `save_draft/4` and `delete_alert/3` never scope by: an
  organization edits one list of alerts whichever version the navigation happens
  to have selected (AC-8, CR-5).

  The route, stop and departure identities a write adds are read back through
  `Alerts.Targets` inside the same transaction, so an answer can only name rows
  of the organization's active schedule, whichever caller wrote it: the editor's
  cards, its generic autosave or an assistant's prepared change (R1, CR-4). A save
  that changed nothing an operator *selected* - a message edit, a timing edit -
  revalidates nothing: `ScopeAnswer.digest/1` of the stored answer still matches
  the stored capture, so the trusted wire IDs, labels and zone the alert keeps
  survive the save untouched (CR-5). A save that changes the selection validates
  only what it adds and merges the capture of what it validates with the capture
  it already held for the unchanged selections the active schedule lacks, so a
  partial repair never has to resolve every old missing ID. `retarget/5` is the
  explicit action that replaces the complete target selection from the active
  schedule and revalidates every identity and its applicability.

  `workspace/2` takes one UTC instant and classifies each row in that alert's
  own retained zone, so an organization holding alerts from several versions and
  several timezones sees each row on its own civil day. The UTC fallback an alert
  with no zone reads in is a presentation answer and never a publication consent
  (CR-5, CR-7). Its targets are resolved against the organization's one active
  schedule in the same short transaction, never against the version an alert was
  first written against; `list_alerts/2` returns only its tabs.

  `save_draft/4` carries the client's expected revision. At the current revision
  it increments the revision and recomputes `effect`, `complete`, `first_date`
  and `last_date` from the answers being saved; at an older revision it changes
  nothing and returns `{:error, :stale, current}` for the editor's conflict
  banner (R6). `delete_alert/3` follows the same order and refuses a stale
  revision the same way.

  `save_review/5` is the same private save plus an explicit publication
  checkbox, and it is the only path that reads that checkbox. An unchecked save
  or an autosave touches nothing public: the served content, its revision and its
  publication date are exactly what they were. A checked save validates
  completeness, the trusted captured selectors and wire representability, compiles
  the civil timing into explicit UTC periods and stores exactly the revision that
  just committed as this alert's desired public intent - so a later autosave stays
  private and no draft is ever published automatically (INV-3, AC-11, AC-14).

  Before accepting anything it measures a conservative envelope of every
  non-withdrawn accepted snapshot the organization has, including the scheduled
  ones, against the same 16 MiB ceiling the encoder enforces. A candidate that
  does not fit is refused and the previous accepted intent is left untouched, so
  the corrective removal stays available even while the feed cannot be projected
  at all (AC-21).

  The script and guidelines commands below hold the same membership lock before
  the script or settings row, so a revocation that commits while a settings save
  is waiting refuses that save too (R5, CR-3). They carry no GTFS version: a
  script and an organization's guidelines are written once and read by every
  alert the organization writes. Reading them writes nothing - an organization
  with no settings row reads the built-in defaults at revision 0 - and a
  built-in script is never edited in place; `copy_built_in_script/2` is the only
  way a default becomes an organization's own (AC-11).
  """

  import Ecto.Changeset
  import Ecto.Query, warn: false

  alias Ecto.Changeset
  alias GtfsPlanner.Alerts.Alert
  alias GtfsPlanner.Alerts.AlertScript
  alias GtfsPlanner.Alerts.AlertSettings
  alias GtfsPlanner.Alerts.BuiltInScripts
  alias GtfsPlanner.Alerts.Completion
  alias GtfsPlanner.Alerts.FeedPeriods
  alias GtfsPlanner.Alerts.Listing
  alias GtfsPlanner.Alerts.Publication
  alias GtfsPlanner.Alerts.Recurrence
  alias GtfsPlanner.Alerts.ScopeAnswer
  alias GtfsPlanner.Alerts.Targets
  alias GtfsPlanner.Alerts.TimingAnswer
  alias GtfsPlanner.Authorization
  alias GtfsPlanner.Gtfs.AuditContext
  alias GtfsPlanner.Gtfs.DisplayClock
  alias GtfsPlanner.Gtfs.ServiceQueries
  alias GtfsPlanner.Repo
  alias GtfsPlanner.Versions

  @type error :: :forbidden | :not_found | Changeset.t()

  @typedoc """
  A write refused because the client's revision is behind the stored one. It
  carries the current alert so the editor can offer the conflict banner.
  """
  @type stale :: {:error, :stale, Alert.t()}

  @typedoc """
  What a reviewed save did with public intent.

  `:private` is an unchecked save or an autosave, `:pending` is an accepted
  revision whose notice has begun, `:scheduled` is an accepted revision whose
  notice has not, and `{:refused, field_errors}` is a private save that committed
  while the publication it was asked for did not.
  """
  @type publication_outcome ::
          :private | :pending | :scheduled | {:refused, [Publication.field_error()]}

  @typedoc """
  A reviewed save: the committed draft and what it did with public intent.
  """
  @type review_result :: %{alert: Alert.t(), publication: publication_outcome()}

  @target_messages %{
    routes: "Choose routes from this version.",
    stops: "Choose stops from this version.",
    trips: "Choose departures from this version."
  }

  @inapplicable_message "Choose stops, stretches and departures the chosen routes serve on those dates."

  @type tabs :: %{
          current: [Listing.row()],
          upcoming: [Listing.row()],
          in_progress: [Listing.row()],
          past: [Listing.row()]
        }

  @typedoc "What `workspace/2` reads, all from one active schedule."
  @type workspace :: %{
          active: Versions.active_schedule(),
          groups: tabs(),
          routes_by_id: %{optional(String.t()) => GtfsPlanner.Gtfs.Route.t()},
          diagnostics_by_alert: %{optional(Ecto.UUID.t()) => [Targets.diagnostic()]}
        }

  @typedoc """
  One script as `list_scripts/1` returns it: the templates `Alerts.Message`
  fills, the situation an editor's answer is matched against, and the key
  `MessageAnswer.script_key` records.
  """
  @type script_option :: %{
          required(:key) => String.t(),
          required(:name) => String.t(),
          required(:situation) => atom(),
          required(:header_template) => String.t(),
          required(:description_template) => String.t(),
          required(:built_in?) => boolean(),
          required(:id) => Ecto.UUID.t() | nil,
          optional(:position) => integer() | nil
        }

  @doc """
  Reads one alert of the context's organization.

  Membership is resolved without a lock, because a read takes nothing and holds
  nothing; the editor role and the organization scope are the same two conditions
  every write applies. The alert's source version is not part of the scope: an
  organization reads its own alert whether or not the version it was written
  against still exists (AC-8).
  """
  @spec get_alert(AuditContext.t(), Ecto.UUID.t() | term()) ::
          {:ok, Alert.t()} | {:error, :forbidden | :not_found}
  def get_alert(%AuditContext{} = audit_context, alert_id) do
    with :ok <- Authorization.authorize_editor(audit_context) do
      case scoped_alert(audit_context, alert_id) do
        %Alert{} = alert -> {:ok, alert}
        nil -> {:error, :not_found}
      end
    end
  end

  @doc """
  Names the service version an alert belongs to, for the editor's own redirect.

  `get_alert/2` answers `:not_found` for an alert of another version, which is
  the answer R1 requires: the alert's content is never read through a version
  the editor is not editing. The editor still has to say *where* the alert went,
  so this reads only the `gtfs_versions.name` of the row whose ID the editor
  holds, scoped to the editor's own organization. It returns a name, never the
  alert and never anything from another organization, so a forged UUID from
  another tenant is still `:not_found` and the editor gets the same
  "that alert is not here" answer.
  """
  @spec version_name_for(AuditContext.t(), Ecto.UUID.t() | term()) ::
          {:ok, String.t()} | {:error, :forbidden | :not_found}
  def version_name_for(%AuditContext{} = audit_context, alert_id) do
    with :ok <- Authorization.authorize_editor(audit_context),
         true <- uuid?(alert_id),
         name when is_binary(name) <- version_name(audit_context.organization_id, alert_id) do
      {:ok, name}
    else
      {:error, :forbidden} -> {:error, :forbidden}
      _not_found -> {:error, :not_found}
    end
  end

  defp version_name(organization_id, alert_id) do
    from(a in Alert,
      join: v in GtfsPlanner.Versions.GtfsVersion,
      on: v.id == a.source_gtfs_version_id,
      where: a.organization_id == ^organization_id and a.id == ^alert_id,
      select: v.name
    )
    |> Repo.one()
  end

  @doc """
  Reads the alerts workspace as of one UTC instant: the organization's alerts, grouped
  into the four tabs, resolved against its one active schedule.

  The result is a single coherent read:

    * `active` is the schedule every target below was resolved against, and its token;
    * `groups` holds the four tabs, each row classified in that alert's own retained
      zone rather than the active schedule's, so a switch to a schedule in another
      zone moves no existing alert to another civil day;
    * `routes_by_id` holds the route rows the alerts name, keyed by feed ID, read from
      the active schedule;
    * `diagnostics_by_alert` maps every listed alert to its missing and inapplicable
      selectors (`Targets.diagnostic()`), empty when it has none.

  The read runs in one `REPEATABLE READ READ ONLY` transaction and takes no row lock.
  The actor's editor membership, the active schedule with its token, the alerts and
  every target come from the snapshot taken at the first of those reads, so a selection
  change or a mutation of the active version's routes, stops or trips that commits
  meanwhile is seen whole by this read or not at all; the read never mixes two
  schedules. It does not make those writers wait, and they do not make it wait: the
  write paths keep their lock order among themselves. A revocation that commits after
  the snapshot is taken applies to the next read. The window holds only batched
  queries, no external call and no query per alert.

  Returns `{:error, :forbidden}` without a current editor membership, and
  `{:error, :no_active_schedule}` when the organization has none, in which case no list
  data is returned.
  """
  @spec workspace(AuditContext.t(), DateTime.t()) ::
          {:ok, workspace()} | {:error, :forbidden | :no_active_schedule}
  def workspace(%AuditContext{} = audit_context, %DateTime{} = now_utc) do
    Repo.transaction(fn ->
      begin_snapshot_read()

      active =
        case Versions.active_schedule(audit_context) do
          {:ok, %{version: nil}} -> Repo.rollback(:no_active_schedule)
          {:ok, active} -> active
          {:error, :forbidden} -> Repo.rollback(:forbidden)
        end

      alerts =
        from(a in Alert,
          where: a.organization_id == ^audit_context.organization_id and is_nil(a.deleted_at)
        )
        |> Repo.all()

      %{routes_by_id: routes_by_id, diagnostics_by_alert: diagnostics} =
        Targets.resolve(%{audit_context | gtfs_version_id: active.version.id}, alerts)

      %{
        active: active,
        groups: Listing.rows(alerts, now_utc, organization_zone(audit_context), diagnostics),
        routes_by_id: routes_by_id,
        diagnostics_by_alert: diagnostics
      }
    end)
  end

  # `workspace/2` reads from one snapshot. The SQL sandbox already holds an open
  # transaction and cannot change its isolation, so test config selects a no-op adapter
  # and the interleaving cases select the production one.
  defp begin_snapshot_read do
    adapter =
      Application.get_env(:gtfs_planner, :alerts_read_snapshot, ServiceQueries.Snapshot.Repo)

    adapter.begin_read()
  end

  @doc """
  Returns the alerts list page's four tabs as of one UTC instant.

  This is `workspace/2`'s `groups`, kept for callers that need only the tabs. It is
  the same read, not a second query, so it fails the same way: `{:error,
  :no_active_schedule}` lists nothing.
  """
  @spec list_alerts(AuditContext.t(), DateTime.t()) ::
          {:ok, tabs()} | {:error, :forbidden | :no_active_schedule}
  def list_alerts(%AuditContext{} = audit_context, %DateTime{} = now_utc) do
    with {:ok, %{groups: groups}} <- workspace(audit_context, now_utc), do: {:ok, groups}
  end

  @doc """
  Returns the selectors one alert retains that the context's schedule cannot honour.

  This is `workspace/2`'s per-alert diagnostics for a single alert, read against the
  context's version outside `workspace/2`'s snapshot; the editor shows it beside the
  draft it holds. A member without the editor role reads none.
  """
  @spec diagnostics_for(AuditContext.t(), Alert.t()) :: [Targets.diagnostic()]
  def diagnostics_for(%AuditContext{} = audit_context, %Alert{} = alert) do
    with_options(audit_context, fn ->
      %{diagnostics_by_alert: diagnostics} = Targets.resolve(audit_context, [alert])
      Map.fetch!(diagnostics, alert.id)
    end)
  end

  @doc """
  Returns the organization's explicit alert zone, or nil when it has stated none.

  An empty or absent zone is nil rather than UTC: the fallback an alert with no
  retained zone reads in is a display answer, and publication requires an
  explicit valid zone instead (CR-5).
  """
  @spec organization_zone(AuditContext.t()) :: String.t() | nil
  def organization_zone(%AuditContext{} = audit_context) do
    case scoped_settings(audit_context) do
      %AlertSettings{timezone: timezone} when is_binary(timezone) ->
        if String.trim(timezone) == "", do: nil, else: String.trim(timezone)

      _absent ->
        nil
    end
  end

  @doc """
  Returns the agency's current civil time for the context's version.

  `Gtfs.DisplayClock.resolve_zone/2` reports the version's agency zone and any
  disclosed fallback, and `localize_many/2` converts one UTC instant through
  PostgreSQL, so `list_alerts/2` is given the agency's own time to group by.
  """
  @spec agency_now(AuditContext.t()) :: NaiveDateTime.t()
  def agency_now(%AuditContext{
        organization_id: organization_id,
        gtfs_version_id: gtfs_version_id
      }) do
    organization_id
    |> DisplayClock.resolve_zone(gtfs_version_id)
    |> then(&DisplayClock.localize_many([DateTime.utc_now()], &1))
    |> List.first()
  end

  @doc """
  Matches the version's routes on short name, long name or `route_id`.

  Every target lookup below resolves inside the context's organization and
  version, so an alert is always about the schedule it was written against and
  never about the version the editor happens to be looking at now (R1, CR-4).
  Like `get_alert/2` and `list_alerts/2`, each lookup resolves the actor's
  current editor membership first; a member who has lost the role gets no
  options at all, so a lookup is fail-closed rather than a read past the role
  check.
  """
  @spec search_routes(AuditContext.t(), String.t()) :: [Targets.route_option()]
  def search_routes(%AuditContext{} = audit_context, query) do
    with_options(audit_context, fn -> Targets.search_routes(audit_context, query) end)
  end

  @doc """
  Matches the version's selectable stops, preferred and excluded as named.

  `:prefer_route_ids` lists the stops those routes serve first and
  `:exclude_stop_ids` drops the stops the alert already names.
  """
  @spec search_stops(AuditContext.t(), String.t(), keyword()) :: [Targets.stop_option()]
  def search_stops(%AuditContext{} = audit_context, query, opts \\ []) do
    with_options(audit_context, fn -> Targets.search_stops(audit_context, query, opts) end)
  end

  @doc """
  Returns the stop options the given feed IDs name, keyed by that feed ID.

  A pick in the editor's stop combobox is an identity that arrived from a
  widget, so it is re-read here before it is stored: an ID of another version,
  another organization or a stop this version no longer holds is absent from the
  result, and the caller stores nothing for it. A stop the editor could not
  have searched for cannot be stored by naming its ID (R1, CR-4).
  """
  @spec stops_by_id(AuditContext.t(), [String.t()]) :: %{
          optional(String.t()) => Targets.stop_option()
        }
  def stops_by_id(%AuditContext{} = audit_context, ids) do
    with_lookup(audit_context, fn -> Targets.stops_by_id(audit_context, ids) end)
  end

  @doc """
  Lists the stops the version's route serves, in the order its trips serve them.
  """
  @spec route_stops(AuditContext.t(), String.t()) :: [Targets.stop_option()]
  def route_stops(%AuditContext{} = audit_context, route_id) do
    with_options(audit_context, fn -> Targets.route_stops(audit_context, route_id) end)
  end

  @doc """
  Lists the version's routes that serve any of the given stops.
  """
  @spec routes_at_stops(AuditContext.t(), [String.t()]) :: [Targets.route_option()]
  def routes_at_stops(%AuditContext{} = audit_context, stop_ids) do
    with_options(audit_context, fn -> Targets.routes_at_stops(audit_context, stop_ids) end)
  end

  @doc """
  Lists the version's route's departures on one date, earliest first.

  Only trips whose service is active on that date are offered, exceptions
  included, so a cancellation step cannot offer a departure the trip does not
  run.
  """
  @spec departures_on(AuditContext.t(), String.t(), 0 | 1 | nil, Date.t()) :: [
          Targets.departure()
        ]
  def departures_on(%AuditContext{} = audit_context, route_id, direction_id, %Date{} = date) do
    with_options(audit_context, fn ->
      Targets.departures_on(audit_context, route_id, direction_id, date)
    end)
  end

  @doc """
  Lists the distinct route types the version contains, ascending.
  """
  @spec route_types(AuditContext.t()) :: [integer()]
  def route_types(%AuditContext{} = audit_context) do
    with_options(audit_context, fn -> Targets.route_types(audit_context) end)
  end

  @doc """
  Lists the directions the given routes run, in the reader's words.

  The ids are route feed IDs from this context's version, the same identities the
  scope answer stores, so the direction question offers directions of the routes
  the alert already names and nothing else (R1, CR-4).
  """
  @spec route_directions(AuditContext.t(), [term()]) :: [Targets.direction_option()]
  def route_directions(%AuditContext{} = audit_context, route_ids) do
    with_options(audit_context, fn -> Targets.route_directions(audit_context, route_ids) end)
  end

  @doc """
  Returns the labels of the routes, stops and trips the alert's scope names,
  keyed by the same feed IDs the alert stored.

  The labels are read from the schedule the context names, which is the active
  schedule for the editor, because an alert names the schedule's entities and not
  one source version's rows. An identity that schedule does not have has no label,
  and the editor lists it as a target to repair instead of inventing a name for it.
  The alert's stored `target_reference` still carries the wire IDs and labels it
  was captured with for the public feed (CR-5).
  """
  @spec labels_for(AuditContext.t(), Alert.t()) :: %{
          routes: %{optional(String.t()) => String.t()},
          stops: %{optional(String.t()) => String.t()},
          trips: %{optional(String.t()) => String.t()}
        }
  def labels_for(%AuditContext{} = audit_context, %Alert{} = alert) do
    case Authorization.authorize_editor(audit_context) do
      :ok -> Targets.labels_for(audit_context, alert)
      {:error, :forbidden} -> %{routes: %{}, stops: %{}, trips: %{}}
    end
  end

  @doc """
  Returns the route rows for a list of alerts, keyed by alert id and then by the
  route feed IDs the alert stored.

  The rows come from the schedule the context names (the active schedule for the
  editor's preview) in one query for every route the alerts name. It is the same
  scoped read `labels_for/2` performs, so a route the schedule lacks is absent from
  both and the Needs attention note explains why (R8, CR-5).
  """
  @spec routes_for(AuditContext.t(), [Alert.t()]) :: %{
          optional(Ecto.UUID.t()) => %{optional(String.t()) => map()}
        }
  def routes_for(%AuditContext{} = audit_context, alerts) when is_list(alerts) do
    case Authorization.authorize_editor(audit_context) do
      :ok ->
        ids = Enum.flat_map(alerts, &Listing.referenced_ids(&1).routes)
        routes = Targets.routes_by_id(audit_context, ids)

        Map.new(alerts, fn alert -> {alert.id, routes} end)

      {:error, :forbidden} ->
        %{}
    end
  end

  # A target lookup takes no lock and writes nothing, so it authorizes rather
  # than locks, exactly as the other reads here do. A member without the editor
  # role reads no options; the refusal is the empty result the caller already
  # renders as "nothing to choose".
  defp with_options(%AuditContext{} = audit_context, fun), do: authorized(audit_context, [], fun)

  # An id lookup answers a map, so a refused member reads the empty map.
  defp with_lookup(%AuditContext{} = audit_context, fun), do: authorized(audit_context, %{}, fun)

  defp authorized(audit_context, refused, fun) do
    case Authorization.authorize_editor(audit_context) do
      :ok -> fun.()
      {:error, :forbidden} -> refused
    end
  end

  @doc """
  Inserts a revision-1 draft in the context's organization, written against its
  active schedule.

  `opts` carries `expected_schedule: token`, the `Versions.selection_token()` the
  caller read with the values it is proposing. The alert is created only while that
  token is still the organization's: `{:error, :stale_active}` when the selection
  has moved (or the token is absent or forged) and `{:error, :no_active_schedule}`
  when there is no active schedule to write against, in either case with nothing
  stored. The version the navigation shows plays no part.

  `created_by_id`, `updated_by_id` and the timing `time_zone` are server-owned:
  the zone is resolved from the active version's agency through
  `Gtfs.DisplayClock.resolve_zone/2` and cannot be cast from a form param, so
  every stored time is read in the agency's own zone (R12). The alert's own
  `timezone` and `target_reference` are captured here as well: `timezone` is the
  active version's single usable agency zone, and `target_reference` is the
  trusted wire IDs, labels and zone `Alerts.Targets` reads from that same
  version. Neither is cast from the attributes (CR-5).
  """
  @spec create_alert(AuditContext.t(), map(), keyword()) ::
          {:ok, Alert.t()}
          | {:error, :forbidden | :stale_active | :no_active_schedule | Changeset.t()}
  def create_alert(%AuditContext{} = audit_context, attrs, opts) when is_list(opts) do
    transaction(fn ->
      active = active_context!(audit_context, opts)

      %Alert{}
      |> Alert.draft_changeset(attrs)
      |> validate_whole_selection(active)
      |> validate_mode(active)
      |> put_change(:organization_id, active.organization_id)
      |> put_change(:source_gtfs_version_id, active.gtfs_version_id)
      |> put_change(:created_by_id, active.actor_id)
      |> put_change(:updated_by_id, active.actor_id)
      |> put_timing_zone(agency_time_zone(active))
      |> capture_target_reference(active)
      |> derive()
      |> Repo.insert()
      |> commit()
    end)
  end

  @doc """
  Saves the operator's answers at the revision the client holds.

  On success the revision is incremented and `effect`, `complete`, `first_date`
  and `last_date` are recomputed from the answers being saved, so the stored row
  can never disagree with `Completion` or `Recurrence`. The revision is compared
  against the row the transaction holds `FOR UPDATE`, so the check is made
  against the version that committed, and `optimistic_lock/3` states the same
  expectation in the `UPDATE` itself. An older `expected_revision` changes
  nothing and returns `{:error, :stale, current}`; an invalid answer returns
  `{:error, changeset}` and also changes nothing, so the editor keeps the typed
  values.

  A save that changed nothing an operator selected keeps the stored
  `target_reference` and `timezone` exactly as they are, and needs neither an
  active schedule nor a token. That is what lets a message-only edit succeed after
  the source version has been deleted: the trusted wire IDs, labels and zone the
  alert publishes from are the ones it was accepted with, not a fresh reading of
  rows that no longer exist (AC-9, CR-5).

  A save that changes the selection needs `expected_schedule: token` (see
  `create_alert/3`) and validates only the identities it adds against the active
  schedule. The identities it keeps stay as they were, found or not, and so do the
  alert's zone and source provenance; only the capture is merged. Replacing the
  whole selection from the active schedule is `retarget/5`.
  """
  @spec save_draft(AuditContext.t(), Ecto.UUID.t() | term(), integer(), map(), keyword()) ::
          {:ok, Alert.t()} | {:error, error() | :stale_active | :no_active_schedule} | stale()
  def save_draft(
        %AuditContext{} = audit_context,
        alert_id,
        expected_revision,
        attrs,
        opts \\ []
      ) do
    transaction(fn ->
      schedule = lock_schedule!(audit_context, opts)
      alert = lock_alert!(audit_context, alert_id)
      assert_current_revision!(alert, expected_revision)

      # `save_review_revision!/5` already leaves the transaction through
      # `commit/1`, so a refused draft changes nothing here either.
      save_review_revision!(audit_context, schedule, alert, expected_revision, attrs)
    end)
  end

  @doc """
  Saves a reviewed revision, and accepts it for publication when the editor
  checked the box.

  This is the one path that turns private authoring into public intent, so it is
  the one place a checkbox is read. The write itself is always the same private
  save `save_draft/4` performs, at the same expected revision and under the same
  membership, channel and alert locks in that order (INV-1, CR-2); the checkbox
  only decides what happens *after* that save commits.

  `publish?: true` also needs `expected_schedule: token` (see `create_alert/3`)
  and refuses the whole command with `{:error, :stale_active}` or `{:error,
  :no_active_schedule}`, before anything is saved, when the selection is not the
  caller's. Otherwise the complete selection must fit the active schedule: every
  route, stop and departure exists there and every pair, stretch and dated trip
  applies to it. A selection that does not is a publication refusal, not a failed
  save.

  The two outcomes are deliberately separate:

    * `publish?: false` returns `publication: :private`. Nothing in
      `alert_publications` is read or written, the alerts channel is not marked
      dirty, and the served content and its publication date are exactly what
      they were. This is also the path every autosave takes, so a later autosave
      can never become a publication (AC-11).
    * `publish?: true` returns `publication: :pending` when the accepted
      snapshot's notice has begun and `:scheduled` when it has not, after
      storing exactly the revision that just committed as this alert's desired
      public intent.

  A publication that cannot be made is reported apart from the save that did
  happen: `{:ok, %{alert: saved, publication: {:refused, field_errors}}}` with the
  draft committed and the previous accepted intent untouched. `{:error, reason}`
  is reserved for a refusal of the private save itself — forbidden, stale
  revision or an invalid draft — and in either refusal the editor keeps the
  submitted form and the checkbox intent, because nothing here writes either
  back.

  `offset_choices` holds the offsets an editor explicitly saved for ambiguous
  local occurrences, keyed by `FeedPeriods.choice_key/2`. A civil reading that
  does not exist is a field correction and a reading that happens twice is a
  choice the editor has to make; neither is ever resolved by taking the first
  offset (AC-12).
  """
  @spec save_review(AuditContext.t(), Ecto.UUID.t() | term(), integer(), map(), keyword()) ::
          {:ok, review_result()}
          | {:error, error() | :stale_active | :no_active_schedule}
          | stale()
  def save_review(%AuditContext{} = audit_context, alert_id, expected_revision, attrs, opts)
      when is_map(attrs) and is_list(opts) do
    publish? = Keyword.get(opts, :publish?, false)
    offset_choices = Keyword.get(opts, :offset_choices) || %{}

    transaction(fn ->
      schedule = lock_schedule!(audit_context, opts)
      active = if publish?, do: active_context!(schedule, audit_context)

      # Schedule, then channel, then alert. The channel is locked before the
      # alert so two publications of the same organization cannot both read the
      # accepted envelope and each admit on top of the other.
      channel = Publication.lock_channel!(audit_context.organization_id)
      alert = lock_alert!(audit_context, alert_id)
      assert_current_revision!(alert, expected_revision)

      saved = save_review_revision!(audit_context, schedule, alert, expected_revision, attrs)

      if publish? do
        accept_for_publication!(active, channel, saved, offset_choices)
      else
        %{alert: saved, publication: :private}
      end
    end)
  end

  # The private save, shared with `save_draft/5` so a reviewed save and an
  # autosave cannot drift apart. It is committed through `commit/1` before any
  # publication work, which is what makes the two outcomes separable.
  defp save_review_revision!(audit_context, schedule, alert, expected_revision, attrs) do
    %{alert | revision: expected_revision}
    |> Alert.draft_changeset(attrs)
    |> refresh_targets(audit_context, schedule, alert)
    |> put_change(:updated_by_id, audit_context.actor_id)
    |> derive()
    |> optimistic_lock(:revision)
    |> Repo.update()
    |> commit()
  end

  defp accept_for_publication!(active, channel, saved, offset_choices) do
    case accepted_intent(active, saved, offset_choices) do
      {:ok, snapshot, identified} ->
        case Publication.admit(active.organization_id, identified.id, snapshot) do
          :ok ->
            publish!(active, channel, identified, snapshot)

          {:error, field_errors} ->
            # The draft stays saved and the previous accepted intent stays
            # exactly as it was; only the refusal is new.
            %{alert: identified, publication: {:refused, field_errors}}
        end

      {:error, field_errors} ->
        %{alert: saved, publication: {:refused, field_errors}}
    end
  end

  defp publish!(audit_context, channel, saved, snapshot) do
    {:ok, _publication} = Publication.accept(saved, snapshot, audit_context.actor_id)
    Publication.mark_channel_dirty!(channel)

    %{alert: saved, publication: publication_state(snapshot)}
  end

  # An accepted snapshot whose notice has not begun is still accepted public
  # intent, and it already counts against the admission budget. Reporting it as
  # scheduled rather than pending is what keeps a scheduled acceptance from
  # reading as a publication that has already happened (AC-15).
  defp publication_state(%{notice_at: notice_at}),
    do: if(notice_at <= now_unix(), do: :pending, else: :scheduled)

  defp now_unix, do: DateTime.utc_now() |> DateTime.to_unix()

  # Everything between a complete draft and an encodable snapshot, in the order
  # that gives the editor the most actionable correction first.
  defp accepted_intent(active, %Alert{} = alert, offset_choices) do
    with :ok <- complete_for_publication(alert),
         {:ok, zone} <- explicit_zone(active, alert),
         {:ok, compiled} <- compile_periods(alert, zone, offset_choices),
         {:ok, scope} <- accepted_scope(alert, active),
         {:ok, identified} <- public_identity(alert) do
      {:ok, Publication.snapshot(identified, compiled, scope), identified}
    end
  end

  defp complete_for_publication(%Alert{} = alert) do
    case Completion.errors(alert) do
      [] ->
        :ok

      errors ->
        # `Completion.errors/1` returns `{step, field, message}`. The field and
        # its message are what an editor needs, so the step is dropped rather
        # than reported as the field a form would bind.
        {:error, Enum.map(errors, &incomplete_error/1)}
    end
  end

  defp incomplete_error({_step, field, message}), do: Publication.error(field, message)

  # The alert's own retained zone first, then the organization's explicit one.
  # With neither, publication refuses rather than inheriting the disclosed
  # display fallback, which is a presentation answer and never consent (CR-5).
  defp explicit_zone(audit_context, %Alert{timezone: timezone}) do
    case usable_zone(timezone) || usable_zone(organization_zone(audit_context)) do
      nil ->
        {:error,
         [
           Publication.error(
             :time_zone,
             "Set the timezone this alert's times are in before publishing."
           )
         ]}

      zone ->
        {:ok, zone}
    end
  end

  defp usable_zone(zone) when is_binary(zone) do
    case String.trim(zone) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp usable_zone(_zone), do: nil

  defp compile_periods(%Alert{timing: %TimingAnswer{} = timing}, zone, offset_choices) do
    case FeedPeriods.compile(timing, zone, offset_choices) do
      {:ok, compiled} -> {:ok, compiled}
      {:error, field_errors} -> {:error, field_errors}
    end
  end

  defp compile_periods(_alert, _zone, _offset_choices),
    do: {:error, [Publication.error(:timing, "This alert has no timing to publish yet.")]}

  # New public intent is judged against the active schedule the caller holds the
  # lock on, not against the capture the alert was last saved with: every selected
  # route, stop and departure must exist there and every pair, stretch and dated
  # trip must apply to it, or the snapshot is refused and the alert stays Needs
  # attention. The scope it carries is captured from that same schedule, so a
  # selector that went missing and came back is published as what it now is.
  #
  # A mode is not a GTFS identity, so it is expanded into the explicit route ids
  # the active schedule holds for that mode (CR-5).
  defp accepted_scope(%Alert{} = alert, %AuditContext{} = active) do
    mode = alert.scope && alert.scope.mode_route_type
    %{diagnostics_by_alert: diagnostics} = Targets.resolve(active, [alert])

    with :ok <- Publication.refuse_diagnostics(Map.fetch!(diagnostics, alert.id)) do
      reference = Targets.capture_reference(alert.scope, active)
      Publication.scope_from_reference(reference, mode_route_ids(active, mode))
    end
  end

  defp mode_route_ids(_active, nil), do: []

  defp mode_route_ids(%AuditContext{} = active, mode) do
    from(route in GtfsPlanner.Gtfs.Route,
      where: route.organization_id == ^active.organization_id,
      where: route.gtfs_version_id == ^active.gtfs_version_id,
      where: route.route_type == ^mode,
      order_by: [asc: route.route_id],
      select: route.route_id
    )
    |> Repo.all()
  end

  # The stable public identity a served feed keeps across retargets and
  # deletions. It is assigned once, on the first accepted revision, and never
  # changed afterwards: a republished alert has to be the same entity to every
  # consumer that already saw it (AC-13).
  defp public_identity(%Alert{public_entity_id: nil} = alert) do
    identity = Ecto.UUID.generate()

    {:ok, updated} =
      alert
      |> Ecto.Changeset.change(public_entity_id: identity)
      |> Repo.update()

    {:ok, updated}
  end

  defp public_identity(%Alert{} = alert), do: {:ok, alert}

  @doc """
  Replaces the alert's complete target selection from the organization's active
  schedule.

  Retargeting is the explicit repair: the caller names the whole `scope_attrs`
  selection and the `expected_schedule` token it read with the values it is
  proposing, and the active schedule is the only place the selection is resolved.
  No version is named by the caller, so a selection is never interpreted through
  whichever version the editor has selected now or through a client-supplied
  source (AC-22). A token that is not the organization's is `{:error,
  :stale_active}` and no active schedule is `{:error, :no_active_schedule}`.

  The complete selection must fit the active schedule: every identity exists and
  every pair, stretch and dated trip applies. A selection that does not is refused
  through the same `:scope` errors `save_draft/5` uses and nothing is stored.

  On success the alert's `source_gtfs_version_id` and `target_reference` are
  replaced with what the active schedule resolves, its revision is incremented
  like any other write, and `derive/1` recomputes the fields the operator cannot
  set. The alert keeps the `timezone` it was saved with, because its dates and
  times are civil readings in that zone and repairing a target must not move them;
  an alert saved with none takes the active schedule's single agency zone.
  """
  @spec retarget(AuditContext.t(), Ecto.UUID.t() | term(), integer(), term(), map()) ::
          {:ok, Alert.t()}
          | {:error,
             :forbidden | :not_found | :stale_active | :no_active_schedule | Changeset.t()}
          | stale()
  def retarget(
        %AuditContext{} = audit_context,
        alert_id,
        expected_revision,
        expected_schedule,
        scope_attrs
      )
      when is_map(scope_attrs) do
    transaction(fn ->
      active = active_context!(audit_context, expected_schedule: expected_schedule)
      alert = lock_alert!(audit_context, alert_id)
      assert_current_revision!(alert, expected_revision)

      %{alert | revision: expected_revision}
      |> Alert.draft_changeset(%{"scope" => scope_attrs})
      |> validate_complete_selection(active)
      |> put_change(:source_gtfs_version_id, active.gtfs_version_id)
      |> put_change(:updated_by_id, audit_context.actor_id)
      |> capture_target_reference(active, alert.timezone)
      |> derive()
      |> optimistic_lock(:revision)
      |> Repo.update()
      |> commit()
    end)
  end

  @doc """
  Deletes one alert of the context's organization.

  An alert with no accepted public history is removed outright, exactly as it was
  before publication existed: nothing was ever public, so there is nothing to
  withdraw and no tombstone to keep.

  An alert that *has* accepted history is deleted logically instead. The row
  stays with `deleted_at` set, so the trusted selectors, the accepted revision and
  the served content survive; the publication row records the confirmed removal
  while keeping the snapshot a served manifest may still be serving, because a
  re-enable has to reconcile against it rather than publish from nothing. This
  happens while publishing is disabled exactly as it happens while it is enabled:
  nothing here reads configuration, so a disable/delete/re-enable cycle cannot
  hide a withdrawal or resurrect the alert (AC-16, FH-14).

  A stale `expected_revision` keeps the row and returns
  `{:error, :stale, current}` in both cases.
  """
  @spec delete_alert(AuditContext.t(), Ecto.UUID.t() | term(), integer()) ::
          {:ok, Alert.t()} | {:error, :forbidden | :not_found} | stale()
  def delete_alert(%AuditContext{} = audit_context, alert_id, expected_revision) do
    transaction(fn ->
      Authorization.lock_editor!(audit_context)
      channel = Publication.lock_channel!(audit_context.organization_id)

      # The row is held `FOR UPDATE` and its revision is checked, so nothing can
      # move the revision between that check and this delete.
      audit_context
      |> lock_alert!(alert_id)
      |> assert_current_revision!(expected_revision)
      |> remove_alert!(channel)
      |> commit()
    end)
  end

  # Removal is the one write an over-budget or corrupt accepted feed cannot
  # block: the refusal from `Publication.admit/3` is reported at acceptance, and
  # this path records the intent regardless of whether the feed can currently be
  # projected at all.
  defp remove_alert!(%Alert{} = alert, channel) do
    case Publication.withdraw(alert) do
      {:ok, _publication} ->
        withdrawn =
          alert
          |> Ecto.Changeset.change(deleted_at: DateTime.utc_now())
          |> Repo.update()

        Publication.mark_channel_dirty!(channel)
        withdrawn

      {:error, _no_history} ->
        Repo.delete(alert)
    end
  end

  @doc """
  Lists the message scripts an editor can choose from: this organization's own
  scripts in their `position` order first, then the read-only built-ins.

  Each option is the shape `Alerts.Message.generate/3` fills, keyed the way
  `MessageAnswer.script_key` stores it - `"org:<uuid>"` for a stored script,
  `"builtin:<key>"` for a default - and carrying `built_in?`, which is what the
  settings table renders as a read-only row with a copy action rather than an
  editable one (AC-11, AC-24).

  A member without the editor role gets no options at all, including no
  built-ins, the same fail-closed read the target lookups above use.
  """
  @spec list_scripts(AuditContext.t()) :: [script_option()]
  def list_scripts(%AuditContext{} = audit_context) do
    with_options(audit_context, fn ->
      org_scripts =
        from(s in AlertScript,
          where: s.organization_id == ^audit_context.organization_id,
          order_by: [asc_nulls_last: s.position, asc: s.inserted_at]
        )
        |> Repo.all()
        |> Enum.map(&script_option/1)

      Enum.concat(org_scripts, Enum.map(BuiltInScripts.scripts(), &built_in_option/1))
    end)
  end

  @doc """
  Stores one organization's script.

  `organization_id` and, when the caller gives no `position`, the script's place
  in the list are set here from the audit context, so neither can be cast from a
  form param (R4, CR-2).
  """
  @spec create_script(AuditContext.t(), map()) :: {:ok, AlertScript.t()} | {:error, error()}
  def create_script(%AuditContext{} = audit_context, attrs) do
    transaction(fn ->
      Authorization.lock_editor!(audit_context)

      %AlertScript{}
      |> AlertScript.changeset(attrs)
      |> put_change(:organization_id, audit_context.organization_id)
      |> put_default_position(audit_context)
      |> Repo.insert()
      |> commit()
    end)
  end

  @doc """
  Saves an organization's script at the row the transaction holds.

  The script is loaded by the context's organization, so a UUID from another
  tenant is `:not_found` rather than a cross-tenant edit, and it is held
  `FOR UPDATE` before it is read.
  """
  @spec update_script(AuditContext.t(), Ecto.UUID.t() | term(), map()) ::
          {:ok, AlertScript.t()} | {:error, error()}
  def update_script(%AuditContext{} = audit_context, script_id, attrs) do
    transaction(fn ->
      Authorization.lock_editor!(audit_context)
      script = lock_script!(audit_context, script_id)

      script
      |> AlertScript.changeset(attrs)
      |> Repo.update()
      |> commit()
    end)
  end

  @doc """
  Deletes one of the organization's own scripts.

  A built-in has no row and no id here: it is copied into the organization with
  `copy_built_in_script/2` before it can be changed or removed, which is what
  keeps one tenant's edit out of every other tenant's defaults.
  """
  @spec delete_script(AuditContext.t(), Ecto.UUID.t() | term()) ::
          {:ok, AlertScript.t()} | {:error, error()}
  def delete_script(%AuditContext{} = audit_context, script_id) do
    transaction(fn ->
      Authorization.lock_editor!(audit_context)
      script = lock_script!(audit_context, script_id)

      script
      |> Repo.delete()
      |> commit()
    end)
  end

  @doc """
  Copies one built-in script into the organization as an editable script.

  The copy carries the built-in's two templates unchanged, so the wording an
  organization starts from is the recommended wording. Its name is the built-in
  name, numbered when the organization already has a script by that name, so
  copying the same default twice is an ordinary second variant rather than a
  unique-name failure. An unknown key stores nothing and returns
  `{:error, :unknown_built_in}`.
  """
  @spec copy_built_in_script(AuditContext.t(), String.t()) ::
          {:ok, AlertScript.t()} | {:error, error() | :unknown_built_in}
  def copy_built_in_script(%AuditContext{} = audit_context, key) do
    case BuiltInScripts.script(key) do
      nil -> {:error, :unknown_built_in}
      built_in -> insert_copy(audit_context, built_in)
    end
  end

  @doc """
  Reads the organization's writing guidelines and the revision they are at.

  Revision 0 is the recommended default: with no stored row this returns
  `BuiltInScripts.guidelines/0` and writes nothing, so merely opening Settings
  cannot create a row and cannot move a revision. A member without the editor
  role reads no text at all, not even the default.
  """
  @spec get_guidelines(AuditContext.t()) :: %{text: String.t(), revision: non_neg_integer()}
  def get_guidelines(%AuditContext{} = audit_context) do
    case Authorization.authorize_editor(audit_context) do
      :ok ->
        case scoped_settings(audit_context) do
          %AlertSettings{} = settings ->
            %{text: settings.guidelines || "", revision: settings.revision}

          nil ->
            %{text: BuiltInScripts.guidelines(), revision: 0}
        end

      {:error, :forbidden} ->
        %{text: "", revision: 0}
    end
  end

  @doc """
  Stores the guidelines at the revision the editor's form was rendered from.

  `expected_revision` 0 means "no row yet", which stores the first revision as
  1. Any other expectation is compared against the row the transaction holds
  `FOR UPDATE`, and `optimistic_lock(:revision)` states the same expectation in
  the `UPDATE`, so a save from a form rendered before another editor's save is
  refused with `{:error, :stale}` instead of overwriting it (R6, AC-11).
  """
  @spec save_guidelines(AuditContext.t(), String.t(), non_neg_integer()) ::
          {:ok, AlertSettings.t()} | {:error, error() | :stale}
  def save_guidelines(%AuditContext{} = audit_context, guidelines, expected_revision)
      when is_binary(guidelines) and is_integer(expected_revision) and expected_revision >= 0 do
    transaction(fn ->
      Authorization.lock_editor!(audit_context)

      case scoped_settings(audit_context, :write) do
        nil when expected_revision == 0 ->
          %AlertSettings{}
          |> AlertSettings.changeset(%{"guidelines" => guidelines})
          |> put_change(:organization_id, audit_context.organization_id)
          |> put_change(:revision, 1)
          |> Repo.insert()
          |> stale_when_first_save_lost()
          |> commit()

        %AlertSettings{} = settings ->
          assert_settings_revision!(settings, expected_revision)

          # The struct carries the revision being replaced, so
          # `optimistic_lock/2` filters the `UPDATE` on it and increments it in
          # the same statement; no separate change is put on the field.
          %{settings | revision: expected_revision}
          |> AlertSettings.changeset(%{"guidelines" => guidelines})
          |> optimistic_lock(:revision)
          |> Repo.update()
          |> commit()

        nil ->
          Repo.rollback(:stale)
      end
    end)
  end

  # A revision that is not a nonnegative integer cannot be any row's revision,
  # so a forged or mistyped value is refused the same way a stale one is rather
  # than raising inside the editor.
  def save_guidelines(%AuditContext{} = _audit_context, _guidelines, _expected_revision),
    do: {:error, :stale}

  # With no row, `FOR UPDATE` locks nothing, so two first saves can both reach the
  # insert. The one that waits on the unique index lost the race: another editor's
  # first revision is now stored, which is what a stale save means.
  defp stale_when_first_save_lost({:error, %Changeset{errors: errors} = changeset}) do
    if Keyword.has_key?(errors, :organization_id), do: {:error, :stale}, else: {:error, changeset}
  end

  defp stale_when_first_save_lost(result), do: result

  # -- Transaction results -------------------------------------------------

  # A refused write changes nothing: the command's result leaves the
  # transaction through `commit/1`, which rolls the transaction back with the
  # refusal, so a returned `{:error, changeset}` never commits a partial row.
  defp commit({:ok, value}), do: value
  defp commit({:error, reason}), do: Repo.rollback(reason)

  defp transaction(fun) do
    case Repo.transaction(fun) do
      {:ok, value} -> {:ok, value}
      {:error, {:stale, current}} -> {:error, :stale, current}
      {:error, reason} -> {:error, reason}
    end
  end

  # -- Scoped reads and locks ----------------------------------------------

  # The first locks of every alert write that may depend on the schedule:
  # organization `FOR SHARE`, the actor's editor membership, then the active
  # version `FOR UPDATE` when there is one. Nothing is refused here beyond a
  # missing membership; whether a stale or absent selection matters is decided
  # once the command knows what it changes.
  defp lock_schedule!(%AuditContext{} = audit_context, opts) do
    Versions.lock_schedule_for_write!(audit_context, Keyword.get(opts, :expected_schedule))
  end

  # The audit context a target-dependent write resolves against: the locked
  # active version, for the token the caller read. A stale token or no active
  # schedule rolls the transaction back before anything is stored.
  defp active_context!(%AuditContext{} = audit_context, opts) when is_list(opts),
    do: audit_context |> lock_schedule!(opts) |> active_context!(audit_context)

  defp active_context!(%{current?: false}, %AuditContext{}), do: Repo.rollback(:stale_active)
  defp active_context!(%{version: nil}, %AuditContext{}), do: Repo.rollback(:no_active_schedule)

  defp active_context!(%{version: version}, %AuditContext{} = audit_context),
    do: %{audit_context | gtfs_version_id: version.id}

  defp scoped_alert(%AuditContext{organization_id: organization_id}, alert_id) do
    if uuid?(alert_id) do
      from(a in Alert,
        where: a.organization_id == ^organization_id and a.id == ^alert_id
      )
      |> Repo.one()
    end
  end

  # R1: the load is scoped to the context's organization, so an ID from another
  # tenant is not found, and the row is held `FOR UPDATE` before its revision is
  # read. It is one query: a delete that commits while this waits for the lock
  # leaves no row to return, and that reads as `:not_found` rather than raising.
  defp lock_alert!(%AuditContext{organization_id: organization_id}, alert_id) do
    alert =
      if uuid?(alert_id) do
        from(a in Alert,
          where: a.organization_id == ^organization_id and a.id == ^alert_id,
          lock: "FOR UPDATE"
        )
        |> Repo.one()
      end

    alert || Repo.rollback(:not_found)
  end

  defp assert_current_revision!(%Alert{revision: revision} = alert, expected_revision)
       when revision == expected_revision,
       do: alert

  defp assert_current_revision!(%Alert{} = alert, _expected_revision),
    do: Repo.rollback({:stale, alert})

  # -- Scripts and settings ------------------------------------------------

  # A copy is stored through the same transaction and the same changeset as any
  # other script, so the membership lock, the organization scope and the
  # template validation are the ones every other write applies.
  defp insert_copy(%AuditContext{} = audit_context, built_in) do
    transaction(fn ->
      Authorization.lock_editor!(audit_context)

      audit_context
      |> create_script(copy_attrs(audit_context.organization_id, built_in))
      |> case do
        {:ok, script} -> script
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp copy_attrs(organization_id, built_in) do
    %{
      "name" => available_name(organization_id, built_in.name),
      "situation" => Atom.to_string(built_in.situation),
      "header_template" => built_in.header_template,
      "description_template" => built_in.description_template
    }
  end

  # A script belongs to the organization, not to one version: the same wording
  # is offered for every alert the organization writes. It is still loaded only
  # through the context's organization, and `FOR UPDATE` while it is written.
  defp lock_script!(%AuditContext{organization_id: organization_id}, script_id) do
    if uuid?(script_id) do
      from(s in AlertScript,
        where: s.organization_id == ^organization_id and s.id == ^script_id,
        lock: "FOR UPDATE"
      )
      |> Repo.one()
    end
    |> case do
      %AlertScript{} = script -> script
      _absent -> Repo.rollback(:not_found)
    end
  end

  defp script_option(%AlertScript{} = script) do
    %{
      key: "org:#{script.id}",
      id: script.id,
      name: script.name,
      situation: script.situation,
      header_template: script.header_template,
      description_template: script.description_template,
      position: script.position,
      built_in?: false
    }
  end

  defp built_in_option(%{key: key} = built_in) do
    %{
      key: "builtin:#{key}",
      id: nil,
      name: built_in.name,
      situation: built_in.situation,
      header_template: built_in.header_template,
      description_template: built_in.description_template,
      built_in?: true
    }
  end

  # A script saved without a position is listed after the ones that carry one,
  # so a newly created script appears where an operator expects to find it
  # instead of sorting ahead of the list they already arranged.
  defp put_default_position(%Changeset{} = changeset, audit_context) do
    case Changeset.get_field(changeset, :position) do
      nil -> put_change(changeset, :position, next_position(audit_context))
      _given -> changeset
    end
  end

  defp next_position(%AuditContext{organization_id: organization_id}) do
    from(s in AlertScript, where: s.organization_id == ^organization_id)
    |> Repo.aggregate(:count)
    |> Kernel.+(1)
  end

  # Copying the same built-in twice is a second variant, not a duplicate-name
  # failure, so the copy is numbered until the name is free.
  defp available_name(organization_id, name) do
    if taken?(organization_id, name), do: numbered_name(organization_id, name, 2), else: name
  end

  defp numbered_name(organization_id, name, attempt) when attempt <= 100 do
    candidate = "#{name} #{attempt}"

    if taken?(organization_id, candidate) do
      numbered_name(organization_id, name, attempt + 1)
    else
      candidate
    end
  end

  defp numbered_name(_organization_id, name, _attempt), do: "#{name} copy"

  defp taken?(organization_id, name) do
    from(s in AlertScript,
      where: s.organization_id == ^organization_id and s.name == ^name,
      select: 1
    )
    |> Repo.exists?()
  end

  # One settings row per organization. A write reads it `FOR UPDATE` before the
  # revision is compared, so a save that waited for the row sees the revision
  # that committed rather than the one it started from.
  defp scoped_settings(%AuditContext{organization_id: organization_id}, lock \\ :read) do
    query =
      case lock do
        :write ->
          from(s in AlertSettings,
            where: s.organization_id == ^organization_id,
            lock: "FOR UPDATE"
          )

        :read ->
          from(s in AlertSettings, where: s.organization_id == ^organization_id)
      end

    Repo.one(query)
  end

  defp assert_settings_revision!(%AlertSettings{revision: revision}, expected_revision)
       when revision == expected_revision,
       do: :ok

  defp assert_settings_revision!(%AlertSettings{}, _expected_revision), do: Repo.rollback(:stale)

  # -- Derived and server-owned fields -------------------------------------

  # Recomputes the fields the operator cannot set. An invalid answer is returned
  # untouched, so the editor keeps the typed values and the stored row is not
  # half-updated.
  defp derive(%Ecto.Changeset{valid?: false} = changeset), do: changeset

  defp derive(%Ecto.Changeset{} = changeset) do
    alert = Changeset.apply_changes(changeset)
    {first_date, last_date} = Recurrence.date_range(alert)

    changeset
    |> put_change(:effect, Completion.effect_for(alert))
    |> put_change(:complete, Completion.complete?(alert))
    |> put_change(:first_date, first_date)
    |> put_change(:last_date, last_date)
  end

  # The route, stop and departure identities are free strings in the scope
  # answer, so a write that *adds* one re-reads it inside the alert's own
  # organization and source version and refuses the rest. An identity already on
  # the stored row is not re-read: R8 lets a target deleted from the version stay
  # on the alert and flags the row instead of rewriting who it is about.
  #
  # A save that changed nothing an operator selected does no target work at all.
  # `ScopeAnswer.digest/1` still matches the stored capture, so the trusted wire
  # IDs, labels and zone survive the save untouched - which is what lets a
  # message-only edit succeed after the source version has been deleted (AC-9).
  defp refresh_targets(%Changeset{valid?: false} = changeset, _audit_context, _schedule, _stored),
    do: changeset

  defp refresh_targets(
         %Changeset{} = changeset,
         %AuditContext{} = audit_context,
         schedule,
         %Alert{} = stored
       ) do
    alert = Changeset.apply_changes(changeset)

    if ScopeAnswer.digest(alert.scope) == ScopeAnswer.digest(stored.scope) do
      changeset
    else
      active = active_context!(schedule, audit_context)
      added = added_ids(stored, alert)

      changeset
      |> validate_whole_selection(active, added)
      |> validate_mode(active, stored.scope && stored.scope.mode_route_type)
      |> merge_target_reference(active, stored)
    end
  end

  defp added_ids(%Alert{} = stored, %Alert{} = alert) do
    previous = Listing.referenced_ids(stored)

    Map.new(Listing.referenced_ids(alert), fn {table, ids} ->
      {table, ids -- Map.fetch!(previous, table)}
    end)
  end

  # Every identity the changeset carries must resolve inside the context's own
  # organization and source version. A retarget replaces the whole selection, so
  # it validates all of it; a save that changed the selection validates only what
  # it added, because an identity the version has since dropped is still the
  # alert's own target (R8).
  defp validate_whole_selection(%Changeset{valid?: false} = changeset, _audit_context),
    do: changeset

  defp validate_whole_selection(%Changeset{} = changeset, %AuditContext{} = audit_context) do
    ids = changeset |> Changeset.apply_changes() |> Listing.referenced_ids()

    validate_whole_selection(changeset, audit_context, ids)
  end

  defp validate_whole_selection(%Changeset{valid?: false} = changeset, _audit_context, _ids),
    do: changeset

  defp validate_whole_selection(%Changeset{} = changeset, %AuditContext{} = audit_context, ids) do
    audit_context
    |> Targets.unresolved_ids(ids)
    |> Enum.reduce(changeset, fn
      {_table, []}, acc -> acc
      {table, _ids}, acc -> add_error(acc, :scope, Map.fetch!(@target_messages, table))
    end)
  end

  # The whole selection of a retarget: every identity exists in the context's
  # version and every pair, stretch and dated trip applies there. `Targets.resolve/2`
  # reads the same diagnostics the list shows as Needs attention, so a repair the
  # editor stages cannot be accepted here and still flagged afterwards.
  defp validate_complete_selection(%Changeset{valid?: false} = changeset, _audit_context),
    do: changeset

  defp validate_complete_selection(%Changeset{} = changeset, %AuditContext{} = audit_context) do
    alert = Changeset.apply_changes(changeset)
    %{diagnostics_by_alert: diagnostics} = Targets.resolve(audit_context, [alert])

    diagnostics
    |> Map.fetch!(alert.id)
    |> Enum.map(&diagnostic_message/1)
    |> Enum.uniq()
    |> Enum.reduce(changeset, &add_error(&2, :scope, &1))
    |> validate_mode(audit_context)
  end

  defp diagnostic_message(%{kind: :inapplicable}), do: @inapplicable_message
  defp diagnostic_message(%{target_type: :route}), do: @target_messages.routes
  defp diagnostic_message(%{target_type: :stop}), do: @target_messages.stops
  defp diagnostic_message(%{target_type: :trip}), do: @target_messages.trips

  # `mode_route_type` is the one scope selector that is not a row identity, so it
  # is checked against the route types the version contains. A mode the alert
  # already held (`retained`) is not asked again by a save that did not change it.
  defp validate_mode(changeset, audit_context, retained \\ nil)

  defp validate_mode(%Changeset{valid?: false} = changeset, _audit_context, _retained),
    do: changeset

  defp validate_mode(%Changeset{} = changeset, %AuditContext{} = audit_context, retained) do
    mode = changeset |> Changeset.apply_changes() |> then(&(&1.scope && &1.scope.mode_route_type))

    if is_nil(mode) or mode == retained or mode in Targets.route_types(audit_context) do
      changeset
    else
      add_error(changeset, :scope, "Choose a route type this version has.")
    end
  end

  # The server-owned capture of what the alert's answer resolves to, taken from
  # the version named on the changeset. It is written on create and on retarget;
  # a save that changed no selection leaves the stored capture alone and one that
  # changed it merges (`merge_target_reference/3`). `retained_zone` is the zone an
  # alert already holds; it wins over the version's, so only a new alert (or one
  # saved with no zone) takes the version's single usable zone.
  defp capture_target_reference(changeset, audit_context, retained_zone \\ nil)

  defp capture_target_reference(%Changeset{valid?: false} = changeset, _audit_context, _zone),
    do: changeset

  defp capture_target_reference(%Changeset{} = changeset, %AuditContext{} = audit_context, zone) do
    alert = Changeset.apply_changes(changeset)
    reference = Targets.capture_reference(alert.scope, audit_context)
    timezone = zone || reference["timezone"]

    changeset
    |> put_change(:target_reference, Map.put(reference, "timezone", timezone))
    |> put_change(:timezone, timezone)
  end

  # A private save that changed the selection captures the new answer from the
  # active schedule and keeps what the alert already held for the unchanged
  # identities that schedule lacks. Its zone and provenance are the alert's own,
  # so a partial correction rewrites neither the civil-time reading nor the
  # version the rest of the selection was written against.
  defp merge_target_reference(%Changeset{valid?: false} = changeset, _active, _stored),
    do: changeset

  defp merge_target_reference(%Changeset{} = changeset, %AuditContext{} = active, stored) do
    alert = Changeset.apply_changes(changeset)
    fresh = Targets.capture_reference(alert.scope, active)

    put_change(
      changeset,
      :target_reference,
      Targets.merge_reference(fresh, stored.target_reference)
    )
  end

  defp put_timing_zone(%Changeset{} = changeset, time_zone) do
    timing =
      case Changeset.get_field(changeset, :timing) do
        %TimingAnswer{} = answer -> answer
        _absent -> %TimingAnswer{}
      end

    put_embed(changeset, :timing, %{timing | time_zone: time_zone})
  end

  # The timing answer's own zone, disclosed exactly as before: the active
  # schedule's single agency zone, or the answer's already-disclosed fallback.
  # Publication never reads this field as a consent (CR-5).
  defp agency_time_zone(%AuditContext{
         organization_id: organization_id,
         gtfs_version_id: gtfs_version_id
       }) do
    organization_id
    |> DisplayClock.resolve_zone(gtfs_version_id)
    |> Map.fetch!(:timezone)
  end

  defp uuid?(value), do: match?({:ok, _uuid}, Ecto.UUID.cast(value))
end
