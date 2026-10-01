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
  (`lock_editor_membership/1`, mirroring
  `Gtfs.Calendars.lock_editor_membership!/1`). A revocation that commits while
  a save is waiting for that lock therefore refuses the save instead of letting
  it commit (R5). The alert itself is then loaded `FOR UPDATE` scoped by
  organization and version, so a forged UUID from another tenant or another
  version is `:not_found` rather than a leak (R6).

  `save_draft/4` carries the client's expected revision. At the current revision
  it increments the revision and recomputes `effect`, `complete`, `first_date`
  and `last_date` from the answers being saved; at an older revision it changes
  nothing and returns `{:error, :stale, current}` for the editor's conflict
  banner (R6). `delete_alert/3` follows the same order and refuses a stale
  revision the same way.
  """

  import Ecto.Changeset
  import Ecto.Query, warn: false

  alias Ecto.Changeset
  alias GtfsPlanner.Accounts.UserOrgMembership
  alias GtfsPlanner.Alerts.Alert
  alias GtfsPlanner.Alerts.Completion
  alias GtfsPlanner.Alerts.Listing
  alias GtfsPlanner.Alerts.Recurrence
  alias GtfsPlanner.Alerts.Targets
  alias GtfsPlanner.Alerts.TimingAnswer
  alias GtfsPlanner.Gtfs.AuditContext
  alias GtfsPlanner.Gtfs.DisplayClock
  alias GtfsPlanner.Repo

  @editor_role "pathways_studio_editor"

  @type error ::
          :forbidden
          | :not_found
          | Changeset.t()
          | {:stale, Alert.t()}

  @type tabs :: %{
          current: [Listing.row()],
          upcoming: [Listing.row()],
          in_progress: [Listing.row()],
          past: [Listing.row()]
        }

  @doc """
  Reads one alert of the context's organization and version.

  Membership is resolved without a lock, because a read takes nothing and holds
  nothing; the editor role and the organization/version scope are the same two
  conditions every write applies.
  """
  @spec get_alert(AuditContext.t(), Ecto.UUID.t() | term()) ::
          {:ok, Alert.t()} | {:error, :forbidden | :not_found}
  def get_alert(%AuditContext{} = audit_context, alert_id) do
    with :ok <- authorize_editor(audit_context) do
      case scoped_alert(audit_context, alert_id) do
        %Alert{} = alert -> {:ok, alert}
        nil -> {:error, :not_found}
      end
    end
  end

  @doc """
  Returns the alerts list page's four tabs as of `local_now`.

  `local_now` is the agency's own civil time, which `agency_now/1` supplies, so
  the tabs and the check-in badge are read in the agency's day rather than UTC's
  and a test can fix the time without a clock override (CR-7). Only the context's
  version's alerts are read; `Alerts.Listing` derives the tab of each row and
  its Needs attention and Check-in due badges from the answers stored on it (R1,
  R8).
  """
  @spec list_alerts(AuditContext.t(), NaiveDateTime.t()) :: {:ok, tabs()} | {:error, :forbidden}
  def list_alerts(%AuditContext{} = audit_context, %NaiveDateTime{} = local_now) do
    with :ok <- authorize_editor(audit_context) do
      alerts =
        from(a in Alert,
          where:
            a.organization_id == ^audit_context.organization_id and
              a.gtfs_version_id == ^audit_context.gtfs_version_id
        )
        |> Repo.all()

      {:ok, Listing.rows(alerts, audit_context.gtfs_version_id, local_now)}
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
  Returns the labels of the routes, stops and trips the alert's scope names,
  keyed by the same row UUIDs the alert stored.
  """
  @spec labels_for(AuditContext.t(), Alert.t()) :: %{
          routes: %{optional(Ecto.UUID.t()) => String.t()},
          stops: %{optional(Ecto.UUID.t()) => String.t()},
          trips: %{optional(Ecto.UUID.t()) => String.t()}
        }
  def labels_for(%AuditContext{} = audit_context, %Alert{} = alert) do
    case authorize_editor(audit_context) do
      :ok -> Targets.labels_for(audit_context, alert)
      {:error, :forbidden} -> %{routes: %{}, stops: %{}, trips: %{}}
    end
  end

  # A target lookup takes no lock and writes nothing, so it authorizes rather
  # than locks, exactly as the other reads here do. A member without the editor
  # role reads no options; the refusal is the empty result the caller already
  # renders as "nothing to choose".
  defp with_options(%AuditContext{} = audit_context, fun) do
    case authorize_editor(audit_context) do
      :ok -> fun.()
      {:error, :forbidden} -> []
    end
  end

  @doc """
  Inserts a revision-1 draft in the context's organization and version.

  `created_by_id`, `updated_by_id` and the timing `time_zone` are server-owned:
  the zone is resolved from the version's agency through
  `Gtfs.DisplayClock.resolve_zone/2` and cannot be cast from a form param, so
  every stored time is read in the agency's own zone (R12).
  """
  @spec create_alert(AuditContext.t(), map()) :: {:ok, Alert.t()} | {:error, error()}
  def create_alert(%AuditContext{} = audit_context, attrs) do
    transaction(fn ->
      lock_editor_membership!(audit_context)

      %Alert{}
      |> Alert.draft_changeset(attrs)
      |> put_change(:organization_id, audit_context.organization_id)
      |> put_change(:gtfs_version_id, audit_context.gtfs_version_id)
      |> put_change(:created_by_id, audit_context.actor_id)
      |> put_change(:updated_by_id, audit_context.actor_id)
      |> put_timing_zone(agency_time_zone(audit_context))
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
  """
  @spec save_draft(AuditContext.t(), Ecto.UUID.t() | term(), integer(), map()) ::
          {:ok, Alert.t()} | {:error, error()}
  def save_draft(%AuditContext{} = audit_context, alert_id, expected_revision, attrs) do
    transaction(fn ->
      lock_editor_membership!(audit_context)
      alert = lock_alert!(audit_context, alert_id)
      assert_current_revision!(alert, expected_revision)

      %{alert | revision: expected_revision}
      |> Alert.draft_changeset(attrs)
      |> put_change(:updated_by_id, audit_context.actor_id)
      |> derive()
      |> optimistic_lock(:revision)
      |> Repo.update()
      |> commit()
    end)
  end

  @doc """
  Deletes one alert of the context's organization and version.

  A stale `expected_revision` keeps the row and returns
  `{:error, :stale, current}`.
  """
  @spec delete_alert(AuditContext.t(), Ecto.UUID.t() | term(), integer()) ::
          {:ok, Alert.t()} | {:error, error()}
  def delete_alert(%AuditContext{} = audit_context, alert_id, expected_revision) do
    transaction(fn ->
      lock_editor_membership!(audit_context)
      alert = lock_alert!(audit_context, alert_id)
      assert_current_revision!(alert, expected_revision)

      changeset =
        %{alert | revision: expected_revision}
        |> change()
        |> optimistic_lock(:revision, stale_error_field: :revision)

      case Repo.delete(changeset) do
        {:ok, deleted} -> commit({:ok, deleted})
        # `stale_error_field` reports a revision that moved under this lock,
        # which the check above already refuses; the rollback keeps the answer
        # the same shape either way.
        {:error, _changeset} -> Repo.rollback({:stale, alert})
      end
    end)
  end

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

  # -- Authorization -------------------------------------------------------

  defp authorize_editor(%AuditContext{
         actor_id: actor_id,
         organization_id: organization_id
       }) do
    case membership(actor_id, organization_id) do
      %UserOrgMembership{deactivated_at: nil, roles: roles} ->
        if editor_role?(roles), do: :ok, else: {:error, :forbidden}

      _other ->
        {:error, :forbidden}
    end
  end

  # R5: the membership is resolved inside the transaction and held `FOR SHARE`,
  # before the alert row is locked or its revision read, so a role removal that
  # commits while this waits refuses the write instead of racing it.
  defp lock_editor_membership!(%AuditContext{} = audit_context) do
    case membership(audit_context.actor_id, audit_context.organization_id) do
      %UserOrgMembership{deactivated_at: nil, roles: roles} ->
        if editor_role?(roles), do: :ok, else: Repo.rollback(:forbidden)

      _other ->
        Repo.rollback(:forbidden)
    end
  end

  defp membership(actor_id, organization_id) do
    if uuid?(actor_id) and uuid?(organization_id) do
      from(m in UserOrgMembership,
        where: m.user_id == ^actor_id and m.organization_id == ^organization_id,
        lock: "FOR SHARE"
      )
      |> Repo.one()
    end
  end

  defp editor_role?(roles) when is_list(roles), do: @editor_role in roles
  defp editor_role?(_roles), do: false

  # -- Scoped reads and locks ----------------------------------------------

  defp scoped_alert(
         %AuditContext{
           organization_id: organization_id,
           gtfs_version_id: gtfs_version_id
         },
         alert_id
       ) do
    if uuid?(alert_id) do
      from(a in Alert,
        where:
          a.organization_id == ^organization_id and
            a.gtfs_version_id == ^gtfs_version_id and
            a.id == ^alert_id
      )
      |> Repo.one()
    end
  end

  # R1: the load is scoped to the context's organization and version, so an ID
  # from another tenant or another version of the same tenant is not found, and
  # the row is held `FOR UPDATE` before its revision is read.
  defp lock_alert!(%AuditContext{} = audit_context, alert_id) do
    case scoped_alert(audit_context, alert_id) do
      %Alert{id: id} ->
        from(a in Alert, where: a.id == ^id, lock: "FOR UPDATE")
        |> Repo.one!()

      nil ->
        Repo.rollback(:not_found)
    end
  end

  defp assert_current_revision!(%Alert{revision: revision} = alert, expected_revision)
       when revision == expected_revision,
       do: alert

  defp assert_current_revision!(%Alert{} = alert, _expected_revision),
    do: Repo.rollback({:stale, alert})

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

  defp put_timing_zone(%Changeset{} = changeset, time_zone) do
    timing =
      case Changeset.get_field(changeset, :timing) do
        %TimingAnswer{} = answer -> answer
        _absent -> %TimingAnswer{}
      end

    put_embed(changeset, :timing, %{timing | time_zone: time_zone})
  end

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
