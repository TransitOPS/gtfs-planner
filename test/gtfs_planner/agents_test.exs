defmodule GtfsPlanner.AgentsTest.VanishingSession do
  @moduledoc """
  Test-only stand-in for a session that ends while a caller attaches.

  It registers the same unique registry key a real session would use and then
  stops without replying when `:attach` arrives. That is the race `Agents.open/1`
  must absorb: the registry lookup found a session, but the process is gone by
  the time the caller attaches.
  """

  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, :ok, opts)

  @impl true
  def init(:ok), do: {:ok, :ok}

  @impl true
  def handle_call(:attach, _from, state), do: {:stop, :shutdown, state}
end

defmodule GtfsPlanner.AgentsTest do
  use GtfsPlanner.DataCase, async: false

  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Agents
  alias GtfsPlanner.Agents.Packs.Alerts
  alias GtfsPlanner.Agents.Packs.Blocks
  alias GtfsPlanner.Agents.Packs.Calendars
  alias GtfsPlanner.Agents.Packs.Connections
  alias GtfsPlanner.Agents.Packs.DatedChanges
  alias GtfsPlanner.Agents.Packs.InSeat
  alias GtfsPlanner.Agents.Packs.Runs
  alias GtfsPlanner.Agents.Packs.ServiceQueries
  alias GtfsPlanner.Agents.Packs.StationImports
  alias GtfsPlanner.Agents.Packs.StationResults
  alias GtfsPlanner.Agents.Packs.Timetables
  alias GtfsPlanner.Agents.Packs.Transfers
  alias GtfsPlanner.Agents.Scope
  alias GtfsPlanner.Agents.SessionSupervisor
  alias GtfsPlanner.Agents.TurnSupervisor
  alias GtfsPlanner.AgentsTest.VanishingSession

  @registry GtfsPlanner.Agents.Registry
  @pack_id "calendars"

  setup do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    user = user_fixture()
    membership = organization_membership_fixture(user, organization)

    %{organization: organization, version: version, user: user, membership: membership}
  end

  describe "the pack registry" do
    test "packs/0 maps every shipped pack id to its module" do
      assert Agents.packs() == %{
               "alerts" => Alerts,
               "blocks" => Blocks,
               "calendars" => Calendars,
               "connections" => Connections,
               "dated_changes" => DatedChanges,
               "feed_quality" => GtfsPlanner.Agents.Packs.FeedQuality,
               "in_seat" => InSeat,
               "runs" => Runs,
               "service_queries" => ServiceQueries,
               "station_imports" => StationImports,
               "station_results" => StationResults,
               "timetables" => Timetables,
               "transfers" => Transfers
             }

      assert Agents.packs() |> Map.keys() |> Enum.sort() ==
               Agents.packs() |> Map.values() |> Enum.map(& &1.id()) |> Enum.sort()
    end
  end

  describe "opening a conversation" do
    test "open/1 returns the same pid and snapshot for the same scope", context do
      scope = scope_for(context.organization, context.version, context.user)

      assert {:ok, pid, snapshot} = Agents.open(scope)
      on_exit(fn -> terminate(pid) end)

      assert is_binary(snapshot.conversation_id)
      assert snapshot.entries == []
      assert snapshot.status == :idle

      assert {:ok, ^pid, ^snapshot} = Agents.open(scope)
      assert Agents.detach(pid) == :ok
      assert {:ok, ^pid, ^snapshot} = Agents.open(scope)
    end

    test "open/1 keeps another person's and another version's conversation apart", context do
      other_user = user_fixture()
      organization_membership_fixture(other_user, context.organization)
      other_version = gtfs_version_fixture(context.organization.id)

      scope = scope_for(context.organization, context.version, context.user)

      other_user_scope = scope_for(context.organization, context.version, other_user)
      other_version_scope = scope_for(context.organization, other_version, context.user)

      assert {:ok, pid, snapshot} = Agents.open(scope)
      assert {:ok, other_user_pid, other_user_snapshot} = Agents.open(other_user_scope)
      assert {:ok, other_version_pid, other_version_snapshot} = Agents.open(other_version_scope)

      for opened <- [pid, other_user_pid, other_version_pid] do
        on_exit(fn -> terminate(opened) end)
      end

      assert pid != other_user_pid
      assert pid != other_version_pid
      assert other_user_pid != other_version_pid
      assert snapshot.conversation_id != other_user_snapshot.conversation_id
      assert snapshot.conversation_id != other_version_snapshot.conversation_id
    end

    test "open/1 reuses one session per route and separates another route of the same version",
         context do
      route = route_fixture(context.organization.id, context.version.id)
      other_route = route_fixture(context.organization.id, context.version.id)

      scope = route_scope(context, route)
      other_scope = route_scope(context, other_route)

      assert {:ok, pid, snapshot} = Agents.open(scope)
      assert {:ok, other_pid, other_snapshot} = Agents.open(other_scope)
      on_exit(fn -> Enum.each([pid, other_pid], &terminate/1) end)

      # A second tab on the same route attaches to the same conversation.
      assert {:ok, ^pid, ^snapshot} = Agents.open(scope)

      assert pid != other_pid
      assert snapshot.conversation_id != other_snapshot.conversation_id
    end

    test "open/1 starts no session for a route the version cannot resolve", context do
      route = route_fixture(context.organization.id, context.version.id)
      other_version = gtfs_version_fixture(context.organization.id)
      foreign_route = route_fixture(context.organization.id, other_version.id)

      active = active_sessions()

      assert Agents.open(route_scope(context, foreign_route)) == {:error, :unavailable}

      assert Agents.open(unknown_route_scope(context)) == {:error, :unavailable}
      assert active_sessions() == active

      assert {:ok, pid, _snapshot} = Agents.open(route_scope(context, route))
      on_exit(fn -> terminate(pid) end)
    end

    test "open/1 starts no session for a deactivated membership", context do
      scope = scope_for(context.organization, context.version, context.user)
      deactivate_membership_fixture(context.membership)

      active = active_sessions()

      assert Agents.open(scope) == {:error, :forbidden}
      assert active_sessions() == active
      assert Registry.lookup(@registry, registry_key(scope)) == []
    end

    test "open/1 refuses a pack the application does not ship", context do
      scope = %{
        scope_for(context.organization, context.version, context.user)
        | pack_id: "unknown"
      }

      assert Agents.open(scope) == {:error, :unknown_pack}
    end

    test "open/1 returns :unavailable at the 200-session cap", context do
      scope = scope_for(context.organization, context.version, context.user)
      active = active_sessions()

      fillers =
        for _index <- 1..(200 - active) do
          child =
            Supervisor.child_spec({Task, fn -> Process.sleep(:infinity) end},
              restart: :temporary
            )

          {:ok, pid} = DynamicSupervisor.start_child(SessionSupervisor, child)
          pid
        end

      on_exit(fn ->
        Enum.each(fillers, &DynamicSupervisor.terminate_child(SessionSupervisor, &1))
      end)

      assert active_sessions() == 200
      assert Agents.open(scope) == {:error, :unavailable}
      assert Registry.lookup(@registry, registry_key(scope)) == []
    end
  end

  describe "the application's agent supervision" do
    test "starts the registry and both bounded supervisors" do
      assert is_pid(Process.whereis(@registry))
      assert is_pid(Process.whereis(SessionSupervisor))
      assert is_pid(Process.whereis(TurnSupervisor))

      assert :sys.get_state(SessionSupervisor).max_children == 200
      assert :sys.get_state(TurnSupervisor).max_children == 8
    end
  end

  describe "ended sessions" do
    test "an attach race with an ending session returns :ended", context do
      scope = scope_for(context.organization, context.version, context.user)
      via = {:via, Registry, {@registry, registry_key(scope)}}

      start_supervised!(Supervisor.child_spec({VanishingSession, name: via}, restart: :temporary))

      assert Agents.open(scope) == {:error, :ended}

      # The ended attach neither killed the caller nor reached a provider.
      assert Agents.send_message(nil, "Are you there?") == {:error, :ended}
    end

    test "calls on an ended or nil session return the documented outcomes", context do
      scope = scope_for(context.organization, context.version, context.user)

      assert {:ok, pid, snapshot} = Agents.open(scope)
      on_exit(fn -> terminate(pid) end)

      assert Agents.stop(pid) == :ok

      assert :ok = DynamicSupervisor.terminate_child(SessionSupervisor, pid)
      refute Process.alive?(pid)

      conversation_id = snapshot.conversation_id

      assert Agents.send_message(pid, "Still there?") == {:error, :ended}
      assert Agents.retry(pid, conversation_id, 1) == {:error, :ended}
      assert Agents.new_conversation(pid) == {:error, :ended}
      assert Agents.prepared(pid, conversation_id, 1) == :error
      assert Agents.record_applied(pid, conversation_id, 1, :command) == {:error, :ended}
      assert Agents.stop(pid) == :ok
      assert Agents.detach(pid) == :ok

      for session <- [nil, :none, "pid"] do
        assert Agents.send_message(session, "Still there?") == {:error, :ended}
        assert Agents.retry(session, conversation_id, 1) == {:error, :ended}
        assert Agents.new_conversation(session) == {:error, :ended}
        assert Agents.prepared(session, conversation_id, 1) == :error
        assert Agents.record_applied(session, conversation_id, 1, :command) == {:error, :ended}
        assert Agents.stop(session) == :ok
        assert Agents.detach(session) == :ok
      end
    end
  end

  ## Fixtures and helpers

  defp scope_for(organization, version, user) do
    %Scope{
      organization_id: organization.id,
      gtfs_version_id: version.id,
      user_id: user.id,
      user_email: user.email,
      pack_id: @pack_id,
      version_name: version.name
    }
  end

  # The identity a Route schedules page binds for the route it shows.
  defp route_scope(context, route) do
    scope_for(context.organization, context.version, context.user)
    |> Map.put(:resource_context, Scope.context({:route, route.id}))
  end

  # A route id the current version cannot resolve, so admission cannot bind it.
  defp unknown_route_scope(context) do
    scope_for(context.organization, context.version, context.user)
    |> Map.put(:resource_context, Scope.context({:route, Ecto.UUID.generate()}))
  end

  defp registry_key(scope) do
    {scope.user_id, scope.organization_id, scope.gtfs_version_id, scope.pack_id,
     Scope.identity(scope), Scope.approved_digest(scope), scope.subject_id,
     Scope.context_digest(scope)}
  end

  defp active_sessions, do: DynamicSupervisor.count_children(SessionSupervisor).active

  defp terminate(pid) do
    if Process.alive?(pid), do: DynamicSupervisor.terminate_child(SessionSupervisor, pid)
  end
end
