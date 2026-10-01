defmodule GtfsPlanner.AlertsFixtures do
  @moduledoc """
  Test helpers for `service_alerts` rows.

  A fixture is built through `GtfsPlanner.Alerts.create_alert/2` rather than by
  inserting a struct, so a test row always carries the server-owned fields the
  commands own: its revision, the organization, version and actor from the
  audit context, and the version's agency time zone. A test that hand-inserted
  a row would prove behavior no editor path can reach.
  """

  alias GtfsPlanner.Alerts

  @doc """
  Generate an alert through `GtfsPlanner.Alerts.create_alert/2`.
  """
  def alert_fixture(audit_context, attrs \\ %{}) do
    {:ok, alert} = Alerts.create_alert(audit_context, attrs)
    alert
  end
end
