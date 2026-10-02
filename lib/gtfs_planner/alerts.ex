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

  Each write runs in one transaction that resolves the actor's *current* active
  membership and holds it `FOR SHARE` before the alert row is locked
  (`Authorization.lock_editor!/1`). A revocation that commits while a save is
  waiting for that lock therefore refuses the save instead of letting it commit
  (R5). The alert itself is then loaded `FOR UPDATE` scoped by organization, so a
  forged UUID from another tenant is `:not_found` rather than a leak (R6).

  An alert belongs to the organization, not to the version it was written
  against. `source_gtfs_version_id` is provenance that a source deletion clears
  and that `get_alert/2`, `save_draft/4` and `delete_alert/3` never scope by: an
  organization edits one list of alerts whichever version the navigation happens
  to have selected (AC-8, CR-5).

  The route, stop and departure identities a write adds are read back through
  `Alerts.Targets` inside the same transaction, so an answer can only name rows
  of the alert's own organization and source version, whichever caller wrote it:
  the editor's cards, its generic autosave or an assistant's prepared change (R1,
  CR-4). A save that changed nothing an operator *selected* - a message edit, a
  timing edit - revalidates nothing: `ScopeAnswer.digest/1` of the stored answer
  still matches the stored capture, so the trusted wire IDs, labels and zone the
  alert keeps survive the save untouched (CR-5). `retarget/5` is the explicit
  action that replaces the complete target selection within one owned version and
  revalidates every identity in it.

  `list_alerts/2` takes one UTC instant and classifies each row in that alert's
  own retained zone, so an organization holding alerts from several versions and
  several timezones sees each row on its own civil day. The UTC fallback an alert
  with no zone reads in is a presentation answer and never a publication consent
  (CR-5, CR-7).

  `save_draft/4` carries the client's expected revision. At the current revision
  it increments the revision and recomputes `effect`, `complete`, `first_date`
  and `last_date` from the answers being saved; at an older revision it changes
  nothing and returns `{:error, :stale, current}` for the editor's conflict
  banner (R6). `delete_alert/3` follows the same order and refuses a stale
  revision the same way.

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
  alias GtfsPlanner.Alerts.Listing
  alias GtfsPlanner.Alerts.Recurrence
  alias GtfsPlanner.Alerts.ScopeAnswer
  alias GtfsPlanner.Alerts.Targets
  alias GtfsPlanner.Alerts.TimingAnswer
  alias GtfsPlanner.Authorization
  alias GtfsPlanner.Gtfs.AuditContext
  alias GtfsPlanner.Gtfs.DisplayClock
  alias GtfsPlanner.Repo

  @type error :: :forbidden | :not_found | Changeset.t()

  @typedoc """
  A write refused because the client's revision is behind the stored one. It
  carries the current alert so the editor can offer the conflict banner.
  """
  @type stale :: {:error, :stale, Alert.t()}

  @target_messages %{
    routes: "Choose routes from this version.",
    stops: "Choose stops from this version.",
    trips: "Choose departures from this version."
  }

  @type tabs :: %{
          current: [Listing.row()],
          upcoming: [Listing.row()],
          in_progress: [Listing.row()],
          past: [Listing.row()]
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
  Returns the alerts list page's four tabs as of one UTC instant.

  Every alert of the organization is listed, whichever version it was written
  against, and each row is classified in that alert's own retained zone rather
  than in the zone of the version the editor has selected. `organization_zone/1`
  is the organization's explicit zone, used for an alert whose source version
  declared none; an alert with neither reads the disclosed UTC fallback, which
  never grants publication consent (CR-5, CR-7).
  """
  @spec list_alerts(AuditContext.t(), DateTime.t()) :: {:ok, tabs()} | {:error, :forbidden}
  def list_alerts(%AuditContext{} = audit_context, %DateTime{} = now_utc) do
    with :ok <- Authorization.authorize_editor(audit_context) do
      alerts =
        from(a in Alert,
          where: a.organization_id == ^audit_context.organization_id and is_nil(a.deleted_at)
        )
        |> Repo.all()

      {:ok, Listing.rows(alerts, now_utc, organization_zone(audit_context))}
    end
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
  Returns the stop rows the given row UUIDs name, keyed by that UUID.

  A pick in the editor's stop combobox is an identity that arrived from a
  widget, so it is re-read here before it is stored: a UUID of another version,
  another organization or a stop this version no longer holds is absent from the
  result, and the caller stores nothing for it. A stop the editor could not
  have searched for cannot be stored by naming its UUID (R1, CR-4).
  """
  @spec stops_by_id(AuditContext.t(), [String.t()]) :: %{
          optional(Ecto.UUID.t()) => Targets.stop_option()
        }
  def stops_by_id(%AuditContext{} = audit_context, ids) do
    with_lookup(audit_context, fn -> Targets.stops_by_id(audit_context, ids) end)
  end

  @doc """
  Lists the stops the version's route serves, in the order its trips serve them.
  """
  @spec route_stops(AuditContext.t(), Ecto.UUID.t()) :: [Targets.stop_option()]
  def route_stops(%AuditContext{} = audit_context, route_id) do
    with_options(audit_context, fn -> Targets.route_stops(audit_context, route_id) end)
  end

  @doc """
  Lists the version's routes that serve any of the given stops.
  """
  @spec routes_at_stops(AuditContext.t(), [Ecto.UUID.t()]) :: [Targets.route_option()]
  def routes_at_stops(%AuditContext{} = audit_context, stop_ids) do
    with_options(audit_context, fn -> Targets.routes_at_stops(audit_context, stop_ids) end)
  end

  @doc """
  Lists the version's route's departures on one date, earliest first.

  Only trips whose service is active on that date are offered, exceptions
  included, so a cancellation step cannot offer a departure the trip does not
  run.
  """
  @spec departures_on(AuditContext.t(), Ecto.UUID.t(), 0 | 1 | nil, Date.t()) :: [
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

  The ids are row UUIDs from this context's version, the same identities the
  scope answer stores, so the direction question offers directions of the routes
  the alert already names and nothing else (R1, CR-4).
  """
  @spec route_directions(AuditContext.t(), [term()]) :: [Targets.direction_option()]
  def route_directions(%AuditContext{} = audit_context, route_ids) do
    with_options(audit_context, fn -> Targets.route_directions(audit_context, route_ids) end)
  end

  @doc """
  Returns the labels of the routes, stops and trips the alert's scope names,
  keyed by the same row UUIDs the alert stored.

  The labels are read from the alert's *own* source version rather than the
  version the editor has selected, so a listing that spans several versions shows
  each row against the schedule it was written against. An alert whose source
  version is gone has no rows to read and therefore no labels: its stored
  `target_reference` still carries the wire IDs and labels it was accepted with,
  and the Needs attention badge says why the live rows are absent (CR-5).
  """
  @spec labels_for(AuditContext.t(), Alert.t()) :: %{
          routes: %{optional(Ecto.UUID.t()) => String.t()},
          stops: %{optional(Ecto.UUID.t()) => String.t()},
          trips: %{optional(Ecto.UUID.t()) => String.t()}
        }
  def labels_for(%AuditContext{} = audit_context, %Alert{} = alert) do
    case Authorization.authorize_editor(audit_context) do
      :ok -> Targets.labels_for(source_context(audit_context, alert), alert)
      {:error, :forbidden} -> %{routes: %{}, stops: %{}, trips: %{}}
    end
  end

  @doc """
  Returns the route rows for a list of alerts, keyed by the row UUIDs they stored.

  The list page reads this so each affected route renders as its own identity
  badge rather than as a word an editor has to recognize. The IDs come from the
  whole page at once and are read from each alert's own source version, so a page
  spanning several versions costs one query per version rather than one per row.
  It is the same scoped read `labels_for/2` performs, so a route that no longer
  exists is simply absent from both and the row's Needs attention badge explains
  why (R8, CR-5).
  """
  @spec routes_for(AuditContext.t(), [Alert.t()]) :: %{optional(Ecto.UUID.t()) => map()}
  def routes_for(%AuditContext{} = audit_context, alerts) when is_list(alerts) do
    case Authorization.authorize_editor(audit_context) do
      :ok ->
        alerts
        |> Enum.group_by(& &1.source_gtfs_version_id)
        |> Enum.flat_map(&routes_for_version(audit_context, &1))
        |> Enum.reduce(%{}, &Map.merge(&2, &1))

      {:error, :forbidden} ->
        %{}
    end
  end

  # The audit context the alert's own provenance names, never one a caller chose.
  # A nil source version yields a context with no version, whose scoped reads
  # return nothing rather than falling back to the selected version.
  defp source_context(%AuditContext{} = audit_context, %Alert{source_gtfs_version_id: version_id}) do
    %{audit_context | gtfs_version_id: version_id}
  end

  defp source_context(%AuditContext{} = audit_context, version_id) do
    %{audit_context | gtfs_version_id: version_id}
  end

  # One read for every route identity the alerts of one version name, so a page
  # spanning several versions costs one query per version rather than one per row.
  defp routes_for_version(audit_context, {version_id, version_alerts}) do
    ids = Enum.flat_map(version_alerts, &Listing.referenced_ids(&1).routes)

    Targets.routes_by_id(source_context(audit_context, version_id), ids)
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
  Inserts a revision-1 draft in the context's organization.

  `created_by_id`, `updated_by_id` and the timing `time_zone` are server-owned:
  the zone is resolved from the version's agency through
  `Gtfs.DisplayClock.resolve_zone/2` and cannot be cast from a form param, so
  every stored time is read in the agency's own zone (R12). The alert's own
  `timezone` and `target_reference` are captured here as well: `timezone` is the
  source version's single usable agency zone, and `target_reference` is the
  trusted wire IDs, labels and zone `Alerts.Targets` reads from that same
  version. Neither is cast from the attributes (CR-5).

  An organization with no usable schedule may still author a private draft: with
  no source version there is nothing to resolve, so the alert stores no capture
  and no guessed zone rather than failing to be written (AC-10).
  """
  @spec create_alert(AuditContext.t(), map()) ::
          {:ok, Alert.t()} | {:error, :forbidden | Changeset.t()}
  def create_alert(%AuditContext{} = audit_context, attrs) do
    transaction(fn ->
      Authorization.lock_editor!(audit_context)

      %Alert{}
      |> Alert.draft_changeset(attrs)
      |> validate_whole_selection(audit_context)
      |> validate_mode(audit_context)
      |> put_change(:organization_id, audit_context.organization_id)
      |> put_change(:source_gtfs_version_id, audit_context.gtfs_version_id)
      |> put_change(:created_by_id, audit_context.actor_id)
      |> put_change(:updated_by_id, audit_context.actor_id)
      |> put_timing_zone(agency_time_zone(audit_context))
      |> capture_target_reference(audit_context)
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
  `target_reference` and `timezone` exactly as they are. That is what lets a
  message-only edit succeed after the source version has been deleted: the
  trusted wire IDs, labels and zone the alert publishes from are the ones it was
  accepted with, not a fresh reading of rows that no longer exist (AC-9, CR-5).
  A changed selection is a retarget, which `retarget/5` performs against one
  named version.
  """
  @spec save_draft(AuditContext.t(), Ecto.UUID.t() | term(), integer(), map()) ::
          {:ok, Alert.t()} | {:error, error()} | stale()
  def save_draft(%AuditContext{} = audit_context, alert_id, expected_revision, attrs) do
    transaction(fn ->
      Authorization.lock_editor!(audit_context)
      alert = lock_alert!(audit_context, alert_id)
      assert_current_revision!(alert, expected_revision)

      %{alert | revision: expected_revision}
      |> Alert.draft_changeset(attrs)
      |> refresh_targets(audit_context, alert)
      |> put_change(:updated_by_id, audit_context.actor_id)
      |> derive()
      |> optimistic_lock(:revision)
      |> Repo.update()
      |> commit()
    end)
  end

  @doc """
  Replaces the alert's complete target selection within one owned version.

  Retargeting is the only action that refreshes trusted identities: the caller
  names the version the new selection is written against and the whole
  `scope_attrs` selection, so a selection is never interpreted by reading old
  UUIDs through whichever version the editor has selected now (AC-9).

  The named version must belong to the context's organization, or the command
  answers `{:error, :not_found}` without reading an identity of it. Every
  identity the new selection names must resolve inside that version, so a
  retarget cannot store a partially foreign selection: an unresolved identity is
  refused through the same `:scope` errors `save_draft/4` uses.

  On success the alert's `source_gtfs_version_id`, `timezone` and
  `target_reference` are replaced with what that version resolves, its revision is
  incremented like any other write, and `derive/1` recomputes the fields the
  operator cannot set.
  """
  @spec retarget(AuditContext.t(), Ecto.UUID.t() | term(), integer(), term(), map()) ::
          {:ok, Alert.t()} | {:error, :forbidden | :not_found | Changeset.t()} | stale()
  def retarget(
        %AuditContext{} = audit_context,
        alert_id,
        expected_revision,
        source_version_id,
        scope_attrs
      )
      when is_map(scope_attrs) do
    transaction(fn ->
      Authorization.lock_editor!(audit_context)
      alert = lock_alert!(audit_context, alert_id)
      assert_current_revision!(alert, expected_revision)

      case owned_version(audit_context, source_version_id) do
        nil ->
          Repo.rollback(:not_found)

        version ->
          source_context = %{audit_context | gtfs_version_id: version.id}

          %{alert | revision: expected_revision}
          |> Alert.draft_changeset(%{"scope" => scope_attrs})
          |> validate_whole_selection(source_context)
          |> validate_mode(source_context)
          |> put_change(:source_gtfs_version_id, version.id)
          |> put_change(:updated_by_id, audit_context.actor_id)
          |> capture_target_reference(source_context)
          |> derive()
          |> optimistic_lock(:revision)
          |> Repo.update()
          |> commit()
      end
    end)
  end

  # A version of the context's own organization, or nil. The read is tenant
  # scoped, so a version id of another tenant is absent rather than adopted.
  defp owned_version(%AuditContext{organization_id: organization_id}, version_id) do
    if uuid?(version_id) do
      from(v in GtfsPlanner.Versions.GtfsVersion,
        where: v.organization_id == ^organization_id and v.id == ^version_id
      )
      |> Repo.one()
    end
  end

  @doc """
  Deletes one alert of the context's organization.

  A stale `expected_revision` keeps the row and returns
  `{:error, :stale, current}`.
  """
  @spec delete_alert(AuditContext.t(), Ecto.UUID.t() | term(), integer()) ::
          {:ok, Alert.t()} | {:error, :forbidden | :not_found} | stale()
  def delete_alert(%AuditContext{} = audit_context, alert_id, expected_revision) do
    transaction(fn ->
      Authorization.lock_editor!(audit_context)

      # The row is held `FOR UPDATE` and its revision is checked, so nothing can
      # move the revision between that check and this delete.
      audit_context
      |> lock_alert!(alert_id)
      |> assert_current_revision!(expected_revision)
      |> Repo.delete()
      |> commit()
    end)
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
  defp refresh_targets(%Changeset{valid?: false} = changeset, _audit_context, _stored),
    do: changeset

  defp refresh_targets(
         %Changeset{} = changeset,
         %AuditContext{} = audit_context,
         %Alert{} = stored
       ) do
    alert = Changeset.apply_changes(changeset)

    if ScopeAnswer.digest(alert.scope) == ScopeAnswer.digest(stored.scope) do
      changeset
    else
      source_context = source_context(audit_context, stored)
      added = added_ids(stored, alert)

      changeset
      |> validate_whole_selection(source_context, added)
      |> validate_mode(source_context)
      |> capture_target_reference(source_context)
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

  # `mode_route_type` is the one scope selector that is not a row identity, so it
  # is checked against the route types the version contains.
  defp validate_mode(%Changeset{valid?: false} = changeset, _audit_context), do: changeset

  defp validate_mode(%Changeset{} = changeset, %AuditContext{} = audit_context) do
    mode = changeset |> Changeset.apply_changes() |> then(&(&1.scope && &1.scope.mode_route_type))

    if is_nil(mode) or mode in Targets.route_types(audit_context) do
      changeset
    else
      add_error(changeset, :scope, "Choose a route type this version has.")
    end
  end

  # The server-owned capture of what the alert's answer resolves to, taken from
  # the version named on the changeset. It is written on create and on retarget
  # only; a save that changed no selection leaves the stored capture alone.
  defp capture_target_reference(%Changeset{valid?: false} = changeset, _audit_context),
    do: changeset

  defp capture_target_reference(%Changeset{} = changeset, %AuditContext{} = audit_context) do
    alert = Changeset.apply_changes(changeset)
    reference = Targets.capture_reference(alert.scope, audit_context)

    changeset
    |> put_change(:target_reference, reference)
    |> put_change(:timezone, reference["timezone"])
  end

  defp put_timing_zone(%Changeset{} = changeset, time_zone) do
    timing =
      case Changeset.get_field(changeset, :timing) do
        %TimingAnswer{} = answer -> answer
        _absent -> %TimingAnswer{}
      end

    put_embed(changeset, :timing, %{timing | time_zone: time_zone})
  end

  # The timing answer's own zone, disclosed exactly as before: with no selected
  # version there is no agency to ask, so no zone is claimed and the answer's
  # already-disclosed fallback stands. Publication never reads this field as a
  # consent (CR-5).
  defp agency_time_zone(%AuditContext{gtfs_version_id: nil}), do: "UTC"

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
