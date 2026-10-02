defmodule GtfsPlanner.Agents.Packs.AlertsSessionTest do
  @moduledoc """
  An alerts conversation ends with its alert (FH-27).

  When another editor of the organization deletes the alert a conversation is
  about, the session refuses to open and refuses the next message before any
  provider request, instead of spending the person's allowance on an answer about
  a record that is gone. The sessions are real ones under the application's
  supervisor, so the SQL sandbox is shared (`async: false`). No `Req.Test` stub
  exists in these tests: a provider request would fail the test.
  """

  use GtfsPlanner.DataCase, async: false

  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.AlertsFixtures
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Agents
  alias GtfsPlanner.Agents.Scope
  alias GtfsPlanner.Agents.SessionSupervisor
  alias GtfsPlanner.Gtfs.AuditContext
  alias GtfsPlanner.Repo

  setup do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    actor = editor_fixture(organization)
    agency_fixture(organization.id, version.id)

    alert =
      alert_fixture(
        %AuditContext{
          organization_id: organization.id,
          gtfs_version_id: version.id,
          station_stop_id: nil,
          actor_id: actor.id,
          actor_email: actor.email
        },
        %{"urgency" => "now"}
      )

    scope = %Scope{
      organization_id: organization.id,
      gtfs_version_id: version.id,
      user_id: actor.id,
      user_email: actor.email,
      pack_id: "alerts",
      version_name: version.name,
      subject_id: alert.id,
      resource_context: Scope.context({:version, version.id})
    }

    %{alert: alert, scope: scope}
  end

  test "opens a conversation about an alert that exists", context do
    assert {:ok, pid, _snapshot} = Agents.open(context.scope)
    on_exit(fn -> DynamicSupervisor.terminate_child(SessionSupervisor, pid) end)

    assert is_pid(pid)
  end

  test "refuses to open a conversation about an alert that was deleted", context do
    Repo.delete!(context.alert)

    assert Agents.open(context.scope) == {:error, :unavailable}
  end

  test "refuses the next message once the alert is deleted and ends the session", context do
    assert {:ok, pid, _snapshot} = Agents.open(context.scope)
    ref = Process.monitor(pid)

    Repo.delete!(context.alert)

    assert Agents.send_message(pid, "Route 12 is detouring") == {:error, :unavailable}
    assert_receive {:DOWN, ^ref, :process, ^pid, _reason}
  end
end
