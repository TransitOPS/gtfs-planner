defmodule GtfsPlanner.AgentsSubjectTest do
  @moduledoc """
  AC-25: the session key carries the conversation's subject.

  Two alerts of one person, organization, version and pack are two
  conversations, and the same alert twice is the same one. A Calendar panel
  carries no subject, so its key — and therefore its reuse — is unchanged.
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

  # The calendars pack is the one the application ships, so this file exercises
  # the production key rather than a test-only registration.
  @pack_id "calendars"

  setup do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    user = user_fixture()
    organization_membership_fixture(user, organization)
    agency_fixture(organization.id, version.id)

    first = alert_fixture(audit_context(organization, version, user))
    second = alert_fixture(audit_context(organization, version, user))

    %{
      organization: organization,
      version: version,
      user: user,
      first_alert: first,
      second_alert: second
    }
  end

  describe "a conversation with a subject" do
    test "two alerts of one person and version open two different sessions", context do
      first = scope_for(context, context.first_alert.id)
      second = scope_for(context, context.second_alert.id)

      assert {:ok, first_pid, first_snapshot} = Agents.open(first)
      assert {:ok, second_pid, second_snapshot} = Agents.open(second)

      on_exit(fn -> terminate([first_pid, second_pid]) end)

      assert first_pid != second_pid
      assert first_snapshot.conversation_id != second_snapshot.conversation_id
    end

    test "the same alert opened twice is the same session", context do
      scope = scope_for(context, context.first_alert.id)

      assert {:ok, pid, snapshot} = Agents.open(scope)
      on_exit(fn -> terminate([pid]) end)

      assert {:ok, ^pid, ^snapshot} = Agents.open(scope)
    end
  end

  describe "a conversation without a subject" do
    test "the Calendar scope opened twice is still the same session", context do
      scope = scope_for(context, nil)

      assert scope.subject_id == nil
      assert {:ok, pid, snapshot} = Agents.open(scope)
      on_exit(fn -> terminate([pid]) end)

      assert {:ok, ^pid, ^snapshot} = Agents.open(scope)
    end

    test "a Calendar session and a subject session are different sessions", context do
      calendar = scope_for(context, nil)
      alert = scope_for(context, context.first_alert.id)

      assert {:ok, calendar_pid, _} = Agents.open(calendar)
      assert {:ok, alert_pid, _} = Agents.open(alert)

      on_exit(fn -> terminate([calendar_pid, alert_pid]) end)

      assert calendar_pid != alert_pid
    end
  end

  ## Fixtures and helpers

  defp scope_for(context, subject_id) do
    %Scope{
      organization_id: context.organization.id,
      gtfs_version_id: context.version.id,
      user_id: context.user.id,
      user_email: context.user.email,
      pack_id: @pack_id,
      version_name: context.version.name,
      subject_id: subject_id
    }
  end

  defp audit_context(organization, version, user) do
    %GtfsPlanner.Gtfs.AuditContext{
      organization_id: organization.id,
      gtfs_version_id: version.id,
      station_stop_id: nil,
      actor_id: user.id,
      actor_email: user.email
    }
  end

  defp terminate(pids) do
    Enum.each(pids, &DynamicSupervisor.terminate_child(SessionSupervisor, &1))
  end
end
