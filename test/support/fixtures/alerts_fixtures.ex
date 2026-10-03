defmodule GtfsPlanner.AlertsFixtures do
  @moduledoc """
  Test helpers for `service_alerts` rows.

  A fixture is built through `GtfsPlanner.Alerts.create_alert/3` rather than by
  inserting a struct, so a test row always carries the server-owned fields the
  commands own: its revision, the organization and actor from the audit context,
  the active version it is written against and that version's agency time zone. A
  test that hand-inserted a row would prove behavior no editor path can reach.
  """

  alias GtfsPlanner.Alerts
  alias GtfsPlanner.Gtfs.AuditContext
  alias GtfsPlanner.Versions

  @doc """
  Generate an alert through `GtfsPlanner.Alerts.create_alert/3`, written against
  the version the audit context names (see `active_token!/1`).
  """
  def alert_fixture(audit_context, attrs \\ %{}) do
    {:ok, alert} =
      Alerts.create_alert(audit_context, attrs, expected_schedule: active_token!(audit_context))

    alert
  end

  @doc """
  The `expected_schedule` option a command takes: the selection token as the
  context's actor and organization read it now, without changing the selection.
  """
  def schedule_opts(%AuditContext{} = audit_context),
    do: [expected_schedule: current_token!(audit_context)]

  @doc "The organization's current selection token, read for the context's actor."
  def current_token!(%AuditContext{} = audit_context) do
    {:ok, %{token: token}} = Versions.active_schedule(scope(audit_context))
    token
  end

  @doc """
  The current selection token after making the context's version the active one.

  Alerts are written against the active schedule, and a test builds its rows in
  the version it names, so that version is selected first (as the context's
  actor, an editor) when another one is active. A context with no version reads
  the token as it is.
  """
  def active_token!(%AuditContext{} = audit_context) do
    scope = scope(audit_context)
    {:ok, %{version: active, token: token}} = Versions.active_schedule(scope)

    case {audit_context.gtfs_version_id, active} do
      {nil, _active} ->
        token

      {version_id, %{id: version_id}} ->
        token

      {version_id, _other} ->
        {:ok, %{token: selected}} = Versions.set_active_schedule(scope, version_id, token)
        selected
    end
  end

  defp scope(%AuditContext{} = audit_context),
    do: %{actor_id: audit_context.actor_id, organization_id: audit_context.organization_id}
end
