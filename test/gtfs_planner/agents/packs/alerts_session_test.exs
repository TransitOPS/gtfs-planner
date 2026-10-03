defmodule GtfsPlanner.Agents.Packs.AlertsSessionTest do
  @moduledoc """
  An alerts conversation ends with its alert (FH-27) and with the active schedule
  it was opened under (AC-26, FH-13).

  When another editor of the organization deletes the alert a conversation is
  about, the session refuses to open and refuses the next message before any
  provider request, instead of spending the person's allowance on an answer about
  a record that is gone. The same holds when the organization's active schedule
  moves: the session key carries the selection token, so a conversation opened
  under an earlier token is refused and ended, and a return to the same version
  (A -> B -> A) is a new token that does not revive it. Calendar sessions keep the
  key they had. The sessions are real ones under the application's supervisor, so
  the SQL sandbox is shared (`async: false`). No `Req.Test` stub exists in these
  tests: a provider request would fail the test.
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
    other = gtfs_version_fixture(organization.id)
    actor = editor_fixture(organization)
    agency_fixture(organization.id, version.id)
    agency_fixture(organization.id, other.id)

    audit = %AuditContext{
      organization_id: organization.id,
      gtfs_version_id: version.id,
      station_stop_id: nil,
      actor_id: actor.id,
      actor_email: actor.email
    }

    alert = alert_fixture(audit, %{"urgency" => "now"})

    scope = %Scope{
      organization_id: organization.id,
      gtfs_version_id: version.id,
      user_id: actor.id,
      user_email: actor.email,
      pack_id: "alerts",
      version_name: version.name,
      subject_id: alert.id,
      alert_schedule_token: current_token!(audit),
      resource_context: Scope.context({:version, version.id})
    }

    %{
      alert: alert,
      scope: scope,
      audit: audit,
      organization: organization,
      version: version,
      other: other,
      actor: actor
    }
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

  describe "the active schedule the conversation was opened under" do
    test "the same selection shares one conversation per alert and another alert gets its own",
         context do
      assert {:ok, pid, _snapshot} = Agents.open(context.scope)
      on_exit(fn -> DynamicSupervisor.terminate_child(SessionSupervisor, pid) end)

      assert {:ok, ^pid, _snapshot} = Agents.open(context.scope)

      second = alert_fixture(context.audit, %{"urgency" => "planned"})
      assert {:ok, other_pid, _snapshot} = Agents.open(%{context.scope | subject_id: second.id})
      on_exit(fn -> DynamicSupervisor.terminate_child(SessionSupervisor, other_pid) end)

      assert other_pid != pid
    end

    test "a conversation is refused and ended once the selection has moved, A to B to A included",
         context do
      assert {:ok, pid, _snapshot} = Agents.open(context.scope)
      ref = Process.monitor(pid)

      activate_version!(context.organization, context.other, context.actor)
      returned = activate_version!(context.organization, context.version, context.actor)

      # The active version is the one the conversation was opened on, but the
      # selection is a later one, so the old conversation is not the editor's now.
      assert returned.version.id == context.version.id
      assert returned.token.revision > context.scope.alert_schedule_token.revision

      # The current selection opens a conversation of its own while the old one is
      # still running, because the token is part of the session key.
      current = %{context.scope | alert_schedule_token: returned.token}
      assert {:ok, fresh, _snapshot} = Agents.open(current)
      on_exit(fn -> DynamicSupervisor.terminate_child(SessionSupervisor, fresh) end)

      assert fresh != pid

      # The old one is refused when it is next asked, and ends.
      assert Agents.open(context.scope) == {:error, :unavailable}
      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}
    end

    test "the next message is refused before any provider request once the selection moved",
         context do
      assert {:ok, pid, _snapshot} = Agents.open(context.scope)
      ref = Process.monitor(pid)

      activate_version!(context.organization, context.other, context.actor)

      assert Agents.send_message(pid, "Route 12 is detouring") == {:error, :unavailable}
      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}
    end

    test "a scope bound to no selection never opens", context do
      assert Agents.open(%{context.scope | alert_schedule_token: nil}) ==
               {:error, :unavailable}
    end

    test "Calendar sessions keep their key and ignore the active schedule", context do
      calendar = %Scope{
        organization_id: context.organization.id,
        gtfs_version_id: context.version.id,
        user_id: context.actor.id,
        user_email: context.actor.email,
        pack_id: "calendars",
        version_name: context.version.name,
        resource_context: Scope.context({:version, context.version.id})
      }

      assert {:ok, pid, _snapshot} = Agents.open(calendar)
      on_exit(fn -> DynamicSupervisor.terminate_child(SessionSupervisor, pid) end)

      # A token on a scope that is not Alerts' is not part of the key.
      with_token = %{calendar | alert_schedule_token: context.scope.alert_schedule_token}
      assert {:ok, ^pid, _snapshot} = Agents.open(with_token)

      activate_version!(context.organization, context.other, context.actor)
      assert {:ok, ^pid, _snapshot} = Agents.open(calendar)
    end
  end
end
