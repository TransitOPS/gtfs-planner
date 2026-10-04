defmodule GtfsPlanner.Agents.Packs.HeadsignsSummaryTest do
  @moduledoc """
  Merge evidence (EV-1) for the Headsign helper's admission and summary.

  Every expected number comes from the A01 fixture description in
  `GtfsPlanner.HeadsignHelperFixtures`, written by hand: fifteen Off-peak trips of
  which twelve follow `Downtown Terminal` (the twelfth stored with surrounding
  spaces), two are interlined and one is lowercase, plus two Peak trips that carry
  their own headsign. Scopes are admitted through the real
  `Scope.with_source_snapshot/2`; calls go through `Dispatch` and `Agents.open/1`,
  and the provider fake is the only boundary doubled.
  """

  use GtfsPlanner.DataCase, async: false

  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.HeadsignHelperFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Agents
  alias GtfsPlanner.Agents.Dispatch
  alias GtfsPlanner.Agents.Packs.Headsigns
  alias GtfsPlanner.Agents.Scope
  alias GtfsPlanner.Agents.SessionSupervisor
  alias GtfsPlanner.Gtfs.ChangeLog
  alias GtfsPlanner.Gtfs.RoutePattern
  alias GtfsPlanner.Gtfs.TimedPattern
  alias GtfsPlanner.Gtfs.Trip

  @owner GtfsPlanner.Agents.Model
  @turn_supervisor GtfsPlanner.Agents.TurnSupervisor

  setup {Req.Test, :verify_on_exit!}

  setup do
    Req.Test.set_req_test_to_shared()
    ensure_turn_supervisor()
    track_sessions()

    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    user = user_fixture()
    membership = organization_membership_fixture(user, organization)
    a01 = a01_fixture(organization.id, version.id)

    %{
      organization: organization,
      version: version,
      user: user,
      membership: membership,
      a01: a01
    }
  end

  describe "summarize_headsigns" do
    test "pattern scope reports the default, its owner and the shielded timing", context do
      scope = scope(context, context.a01.route, snapshot(context.a01.pattern))
      before = row_counts()

      assert {:ok, result, evidence} = summarize(scope)

      assert result["scope"] == "pattern"
      assert result["pattern_name"] == "Downtown"
      assert result["timing_name"] == nil
      assert result["default"] == "Downtown Terminal"
      assert result["default_owner"] == "pattern"
      assert {result["total"], result["same"], result["differ"]} == {15, 12, 3}

      assert result["shielded"] == [
               %{"timing" => "Peak", "headsign" => "Peak Terminal", "trips" => 2}
             ]

      assert result["shielded_total"] == 1
      assert result["timings_carry"] == []

      assert result["groups"] == [
               %{"value" => "downtown terminal", "kind" => "case_or_spacing", "trips" => 1},
               %{
                 "value" => "Downtown Terminal, continues to Airport",
                 "kind" => "interline",
                 "trips" => 2
               }
             ]

      assert result["groups_total"] == 2
      assert result["stop_level_note"] =~ "Stop-level headsigns are never changed"

      assert evidence.kind == "headsign_summary"
      assert evidence.total == 15
      assert evidence.total_label == "trips in scope"
      assert evidence.completeness == :complete
      assert evidence.source_ref == "gtfs_headsign_usage"
      assert evidence.digest =~ ~r/\A[0-9a-f]{64}\z/
      assert evidence.source_revision == nil
      assert evidence.resources == []

      # AgentPanel compares the identity label with `kind:id` of the page's context.
      assert evidence.scope == %{
               organization_id: context.organization.id,
               gtfs_version_id: context.version.id,
               identity: "route:#{context.a01.route.id}"
             }

      assert row_counts() == before
    end

    test "timing scope reports the pattern default for Off-peak and its own for Peak", context do
      off_peak =
        scope(context, context.a01.route, snapshot(context.a01.pattern, context.a01.off_peak))

      peak = scope(context, context.a01.route, snapshot(context.a01.pattern, context.a01.peak))

      assert {:ok, result, _evidence} = summarize(off_peak)
      assert result["scope"] == "timing"
      assert result["timing_name"] == "Off-peak"
      assert result["default"] == "Downtown Terminal"
      assert result["default_owner"] == "pattern"
      assert {result["total"], result["same"], result["differ"]} == {15, 12, 3}
      assert result["shielded"] == []

      assert {:ok, result, _evidence} = summarize(peak)
      assert result["timing_name"] == "Peak"
      assert result["default"] == "Peak Terminal"
      assert result["default_owner"] == "timing"
      assert {result["total"], result["same"], result["differ"]} == {2, 2, 0}
      assert result["groups"] == []
    end

    test "a pattern with no headsign reports no default and the timing that carries one",
         context do
      pattern =
        route_pattern_fixture(context.organization.id, context.version.id, %{
          route_id: context.a01.route.route_id,
          route_pattern_id: "A01-IMPORT",
          headsign: nil
        })

      carrying = timed_pattern_fixture(pattern, %{name: "Weekday base", headsign: "Lincoln City"})

      context.organization.id
      |> trip_fixture(context.version.id, context.a01.route.route_id,
        trip_id: "A01-IMPORT-1",
        trip_headsign: "Lincoln City"
      )
      |> trip_pattern_metadata_fixture(%{
        route_pattern_id: pattern.route_pattern_id,
        timed_pattern_id: carrying.id,
        pattern_derivation_state: "linked"
      })

      scope = scope(context, context.a01.route, snapshot(pattern))

      assert {:ok, result, _evidence} = summarize(scope)
      assert result["default"] == nil
      assert result["default_owner"] == "none"
      assert result["total"] == 0

      assert result["timings_carry"] == [
               %{"timing" => "Weekday base", "headsign" => "Lincoln City", "trips" => 1}
             ]
    end
  end

  describe "admission" do
    test "a target the page did not admit is unavailable before any provider request",
         context do
      other_route = route_fixture(context.organization.id, context.version.id, %{route_id: "R9"})

      other_pattern =
        route_pattern_fixture(context.organization.id, context.version.id, %{
          route_id: other_route.route_id,
          route_pattern_id: "A01-OTHER"
        })

      other_timing = timed_pattern_fixture(other_pattern, %{name: "Other timing"})

      other_version = gtfs_version_fixture(context.organization.id)
      {_route, version_pattern} = pattern_in(context.organization, other_version)

      foreign_organization = organization_fixture()
      foreign_version = gtfs_version_fixture(foreign_organization.id)
      {foreign_route, foreign_pattern} = pattern_in(foreign_organization, foreign_version)

      deleted_pattern =
        route_pattern_fixture(context.organization.id, context.version.id, %{
          route_id: context.a01.route.route_id,
          route_pattern_id: "A01-DELETED"
        })

      Repo.delete!(deleted_pattern)

      route_uuid = context.a01.route.id
      pattern_uuid = context.a01.pattern.id

      cases = [
        {"pattern of another route", snapshot_payload(other_pattern.id, nil)},
        {"pattern of another version", snapshot_payload(version_pattern.id, nil)},
        {"pattern of another organization", snapshot_payload(foreign_pattern.id, nil)},
        {"deleted pattern", snapshot_payload(deleted_pattern.id, nil)},
        {"timing of another pattern", snapshot_payload(pattern_uuid, other_timing.id)},
        {"non-UUID pattern", snapshot_payload("not-a-uuid", nil)},
        {"non-UUID timing", snapshot_payload(pattern_uuid, "nope")},
        {"schema version 2", Map.put(snapshot_payload(pattern_uuid, nil), "schema_version", 2)},
        {"no pattern", %{"schema_version" => 1}}
      ]

      for {label, payload} <- cases do
        scope =
          scope(context, context.a01.route, {:ok, %{kind: "headsign_scope", payload: payload}})

        assert Headsigns.authorize_context(scope) == {:error, :unavailable}, label
        assert Agents.open(scope) == {:error, :unavailable}, label

        assert Dispatch.call(Headsigns, scope, "summarize_headsigns", "{}") ==
                 {:error, :unavailable},
               label
      end

      # No snapshot at all, and another pack's snapshot kind, are no scope either.
      no_snapshot = scope(context, context.a01.route, :none)
      assert Agents.open(no_snapshot) == {:error, :unavailable}

      other_kind =
        scope(
          context,
          context.a01.route,
          {:ok, %{kind: "gtfs_timetable_source", payload: snapshot_payload(pattern_uuid, nil)}}
        )

      assert Headsigns.authorize_context(other_kind) == {:error, :unavailable}

      # A foreign route identity never resolves, whatever the snapshot names.
      foreign_identity = scope(context, foreign_route, snapshot(context.a01.pattern))
      assert Agents.open(foreign_identity) == {:error, :unavailable}

      assert route_uuid != foreign_route.id
      refute_provider_called()
    end

    test "a deleted pattern ends an open conversation without a provider request", context do
      gone =
        route_pattern_fixture(context.organization.id, context.version.id, %{
          route_id: context.a01.route.route_id,
          route_pattern_id: "A01-GONE"
        })

      scope = scope(context, context.a01.route, snapshot(gone))
      assert {:ok, session, _snapshot} = Agents.open(scope)

      stub_provider()
      Repo.delete!(gone)

      assert Agents.send_message(session, "Which trips follow the default?") ==
               {:error, :unavailable}

      refute_provider_called()
    end

    test "a deactivated membership refuses the next request, tool and delivered result",
         context do
      scope = scope(context, context.a01.route, snapshot(context.a01.pattern))
      assert {:ok, session, _snapshot} = Agents.open(scope)

      stub_provider()
      deactivate_membership_fixture(context.membership)

      assert Agents.send_message(session, "Which trips follow the default?") ==
               {:error, :forbidden}

      assert Dispatch.call(Headsigns, scope, "summarize_headsigns", "{}") == {:error, :forbidden}
      assert Agents.open(scope) == {:error, :forbidden}
      refute_provider_called()
    end

    test "no tool declares a scope argument and dispatch rejects one", context do
      scope = scope(context, context.a01.route, snapshot(context.a01.pattern))

      scope_keys = ~w(organization_id gtfs_version_id route_id pattern_id timing_id)

      for tool <- Headsigns.tools() do
        assert Map.keys(tool.parameters["properties"]) -- scope_keys ==
                 Map.keys(tool.parameters["properties"])

        assert tool.parameters["additionalProperties"] == false
      end

      for key <- ~w(organization_id gtfs_version_id route_id pattern_id timing_id) do
        assert {:tool_error, "Unexpected argument: " <> ^key} =
                 Dispatch.call(Headsigns, scope, "summarize_headsigns", ~s({"#{key}":"x"}))
      end
    end
  end

  describe "pack declaration" do
    test "the shipped registry names the pack and its prepare-only tools" do
      assert Agents.packs()["headsigns"] == Headsigns
      assert Headsigns.id() == "headsigns"
      assert Headsigns.title() == "Headsign helper"

      # Reads and one prepare tool; no tool is named for a native write (CR-1).
      assert Enum.map(Headsigns.tools(), & &1.name) == [
               "summarize_headsigns",
               "find_headsign_variants",
               "prepare_headsign_change"
             ]

      assert Headsigns.skill() =~ "summarize_headsigns"
    end
  end

  # -- helpers ----------------------------------------------------------------

  defp summarize(scope), do: Dispatch.call(Headsigns, scope, "summarize_headsigns", "{}")

  defp snapshot(pattern, timing \\ nil),
    do:
      {:ok, %{kind: "headsign_scope", payload: snapshot_payload(pattern.id, timing && timing.id)}}

  defp snapshot_payload(pattern_id, timing_id),
    do: %{"schema_version" => 1, "pattern_id" => pattern_id, "timing_id" => timing_id}

  defp scope(context, route, snapshot) do
    base = Scope.context({:route, route.id})

    resource_context =
      case snapshot do
        :none ->
          base

        {:ok, envelope} ->
          {:ok, admitted} = Scope.with_source_snapshot(base, envelope)
          admitted
      end

    %Scope{
      organization_id: context.organization.id,
      gtfs_version_id: context.version.id,
      user_id: context.user.id,
      user_email: context.user.email,
      pack_id: "headsigns",
      version_name: context.version.name,
      resource_context: resource_context
    }
  end

  defp pattern_in(organization, version) do
    route = route_fixture(organization.id, version.id, %{route_id: "R1"})

    {route,
     route_pattern_fixture(organization.id, version.id, %{
       route_id: route.route_id,
       route_pattern_id: "A01-ELSEWHERE"
     })}
  end

  defp row_counts do
    {Repo.aggregate(Trip, :count), Repo.aggregate(RoutePattern, :count),
     Repo.aggregate(TimedPattern, :count), Repo.aggregate(ChangeLog, :count),
     Repo.all(from(t in Trip, order_by: t.id, select: {t.id, t.updated_at, t.trip_headsign}))}
  end

  defp stub_provider do
    test = self()

    Req.Test.stub(@owner, fn conn ->
      send(test, :provider_called)
      Plug.Conn.send_resp(conn, 500, "unexpected provider request")
    end)
  end

  defp refute_provider_called do
    refute_received :provider_called
  end

  defp track_sessions do
    before = session_pids()

    on_exit(fn ->
      for pid <- session_pids(), pid not in before do
        DynamicSupervisor.terminate_child(SessionSupervisor, pid)
      end
    end)
  end

  defp session_pids do
    SessionSupervisor
    |> DynamicSupervisor.which_children()
    |> Enum.map(fn {_id, pid, _type, _modules} -> pid end)
  end

  defp ensure_turn_supervisor do
    if is_nil(Process.whereis(@turn_supervisor)) do
      start_supervised!({Task.Supervisor, name: @turn_supervisor, max_children: 8})
    end
  end
end
