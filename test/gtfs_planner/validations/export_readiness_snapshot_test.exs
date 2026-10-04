defmodule GtfsPlanner.Validations.ExportReadinessSnapshotTest do
  @moduledoc """
  The readiness read opens its read snapshot through the shared boundary.

  Postgrex ignores an `:isolation` option on `Repo.transaction/2`, so the
  isolation level is set by the boundary's first statement
  (`ServiceQueries.Snapshot.Repo`, covered by the service-query race test). The
  SQL sandbox cannot change its enclosing transaction's isolation, so this file
  selects a recording boundary and asserts that one readiness read calls it
  exactly once. It does not exercise a concurrent writer and cannot tell whether
  the call precedes the read's first query: the interleaving itself is that
  boundary's existing test.
  """

  use GtfsPlanner.DataCase, async: false

  alias GtfsPlanner.Agents.Scope
  alias GtfsPlanner.Validations.Evidence

  import GtfsPlanner.AccountsFixtures, only: [editor_fixture: 1]
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  defmodule RecordingSnapshot do
    @moduledoc false
    @behaviour GtfsPlanner.Gtfs.ServiceQueries.Snapshot

    @impl true
    def begin_read do
      owner = Application.fetch_env!(:gtfs_planner, :readiness_snapshot_test_owner)
      send(owner, :begin_read)
      :ok
    end
  end

  setup do
    restore_env(:gtfs_service_query_snapshot)
    restore_env(:readiness_snapshot_test_owner)

    Application.put_env(:gtfs_planner, :gtfs_service_query_snapshot, RecordingSnapshot)
    Application.put_env(:gtfs_planner, :readiness_snapshot_test_owner, self())

    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    user = editor_fixture(organization)

    %{
      scope: %Scope{
        organization_id: organization.id,
        gtfs_version_id: version.id,
        user_id: user.id,
        user_email: user.email,
        pack_id: "feed_quality",
        version_name: version.name,
        resource_context: Scope.context({:version, version.id})
      }
    }
  end

  test "one readiness read opens the snapshot boundary once", %{scope: scope} do
    assert {:ok, _readiness} = Evidence.readiness(scope, :full, nil)

    assert_received :begin_read
    refute_received :begin_read
  end

  # Captures the prior value, including its absence, and restores it exactly.
  defp restore_env(key) do
    previous = Application.fetch_env(:gtfs_planner, key)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:gtfs_planner, key, value)
        :error -> Application.delete_env(:gtfs_planner, key)
      end
    end)
  end
end
