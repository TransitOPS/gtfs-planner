defmodule GtfsPlanner.Gtfs.FareZones.SelectionFenceConcurrencyTest do
  @moduledoc """
  Merge evidence (EV-4) that the selection fence is serialized with a competing
  route-membership writer.

  Two independently committing sessions (`Sandbox.unboxed_run/2`) stand in for a
  schedule editor and a fare editor. Session A is a membership writer: it takes
  the published version row `FOR SHARE`, the mode `Versions.lock_for_input_write!/2`
  gives every schedule writer, and inserts a stop_time that puts the unserved stop
  U1 on trip T6 of route R6, uncommitted. Session B applies a zone assignment that
  was prepared before that change. B's `FOR UPDATE` on the version row must wait
  for A; once A commits, B's recompute sees the new membership and the apply
  refuses with nothing written. A control case with no competing writer commits
  the assignment.

  Proof limit: READ COMMITTED lock ordering against one hand-written `FOR SHARE`
  writer. The reverse order (B holds the row first) follows from row-lock
  exclusivity and is not separately observed. The writers that take the version row
  are listed in the inspection recorded with this evidence, not asserted here.

  A third case holds the version row exclusively, as a fare-zone assignment does,
  and shows that the two editor-provenance derivation writers (the only writers of
  route_pattern_stops and trip linkage that read the version row) wait for it.

  The test is deliberately not `async: true`. It commits a uniquely aliased
  organization and removes every row it committed on exit.
  """
  use ExUnit.Case

  import Ecto.Query
  import GtfsPlanner.ConcurrencyHelpers, only: [delete_committed_scope!: 1, unboxed: 1]

  alias GtfsPlanner.AccountsFixtures
  alias GtfsPlanner.FareSelectionFixtures
  alias GtfsPlanner.Gtfs.AuditContext
  alias GtfsPlanner.Gtfs.FareZones
  alias GtfsPlanner.Gtfs.RoutePatterns.Derivation
  alias GtfsPlanner.Gtfs.Stop
  alias GtfsPlanner.Gtfs.StopTime
  alias GtfsPlanner.OrganizationsFixtures
  alias GtfsPlanner.Repo
  alias GtfsPlanner.Versions
  alias GtfsPlanner.VersionsFixtures

  @predicate %{route_ids: ["R6"], only_unzoned?: true, exclude_stop_ids: ["AIR1"]}

  test "a membership change committed before the apply's lock refuses the apply" do
    supervisor = start_supervised!({Task.Supervisor, name: __MODULE__.TaskSupervisor})
    fixture = committed_fixture("race")
    on_exit(fn -> cleanup(fixture) end)

    parent = self()

    holder =
      Task.Supervisor.async_nolink(supervisor, fn ->
        unboxed(fn ->
          Repo.transaction(fn ->
            Versions.lock_for_input_write!(fixture.organization.id, fixture.version.id)
            {1, nil} = Repo.insert_all(StopTime, [put_u1_on_t6(fixture)])
            send(parent, :membership_written)

            receive do
              :commit -> :committed
            end
          end)
        end)
      end)

    assert_receive :membership_written, 5_000

    writer =
      Task.Supervisor.async_nolink(supervisor, fn ->
        send(parent, :writer_started)

        unboxed(fn ->
          FareZones.apply_assignment(fixture.audit, fixture.changes, selection: fixture.prepared)
        end)
      end)

    assert_receive :writer_started, 5_000
    assert Task.yield(writer, 200) == nil
    assert committed_zones(fixture, ["A1", "A3"]) == %{"A1" => nil, "A3" => nil}

    send(holder.pid, :commit)
    assert Task.await(holder, 10_000) == {:ok, :committed}

    assert Task.await(writer, 10_000) == {:error, :selection_changed}
    assert committed_zones(fixture, ["A1", "A3"]) == %{"A1" => nil, "A3" => nil}
  end

  test "with no competing writer the same prepared apply commits" do
    fixture = committed_fixture("control")
    on_exit(fn -> cleanup(fixture) end)

    assert {:ok, %{applied: applied}} =
             unboxed(fn ->
               FareZones.apply_assignment(fixture.audit, fixture.changes,
                 selection: fixture.prepared
               )
             end)

    assert applied == fixture.changes
    assert committed_zones(fixture, ["A1", "A3"]) == %{"A1" => "B", "A3" => "B"}
  end

  test "editor route derivation waits for a writer holding the version row" do
    supervisor = start_supervised!({Task.Supervisor, name: __MODULE__.TaskSupervisor})
    fixture = committed_fixture("derive")
    on_exit(fn -> cleanup(fixture) end)

    # A route with no trips: derivation has nothing to do, so without the version
    # lock it would return at once rather than merely slowly.
    unboxed(fn ->
      GtfsPlanner.GtfsFixtures.route_fixture(fixture.organization.id, fixture.version.id, %{
        route_id: "RX"
      })
    end)

    parent = self()

    holder =
      Task.Supervisor.async_nolink(supervisor, fn ->
        unboxed(fn ->
          Repo.transaction(fn ->
            Versions.lock_for_exclusive_write!(fixture.organization.id, fixture.version.id)
            send(parent, :version_locked)

            receive do
              :release -> :released
            end
          end)
        end)
      end)

    assert_receive :version_locked, 5_000

    derivation =
      Task.Supervisor.async_nolink(supervisor, fn ->
        unboxed(fn ->
          Derivation.derive_route(
            fixture.organization.id,
            fixture.version.id,
            "RX",
            {:editor, fixture.audit}
          )
        end)
      end)

    grouping =
      Task.Supervisor.async_nolink(supervisor, fn ->
        unboxed(fn -> Derivation.group_left_out("RX", [], "stale-fingerprint", fixture.audit) end)
      end)

    assert Task.yield(derivation, 200) == nil
    assert Task.yield(grouping, 200) == nil

    send(holder.pid, :release)
    assert Task.await(holder, 10_000) == {:ok, :released}

    # Released, both proceed: the derivation runs and the stale review is refused.
    assert {:ok, %{}} = Task.await(derivation, 10_000)
    assert {:error, :stale} = Task.await(grouping, 10_000)
  end

  defp put_u1_on_t6(fixture) do
    now = DateTime.utc_now()

    %{
      organization_id: fixture.organization.id,
      gtfs_version_id: fixture.version.id,
      trip_id: "T6",
      stop_id: "U1",
      stop_sequence: 9,
      arrival_time: "08:30:00",
      departure_time: "08:30:00",
      inserted_at: now,
      updated_at: now
    }
  end

  defp committed_fixture(suffix) do
    unboxed(fn ->
      # config/test.exs only connects to a `gtfs_planner_exunit*` database; check the
      # connection itself before this test commits anything.
      %Postgrex.Result{rows: [[database]]} = Repo.query!("SELECT current_database()")
      assert String.starts_with?(database, "gtfs_planner_exunit")

      organization =
        OrganizationsFixtures.organization_fixture(%{
          alias: "fare-selection-fence-#{suffix}-#{System.system_time(:nanosecond)}"
        })

      version = VersionsFixtures.gtfs_version_fixture(organization.id)
      actor = AccountsFixtures.editor_fixture(organization)
      stops = FareSelectionFixtures.insert_network!(organization, version)
      {:ok, selection} = FareZones.route_selection(organization.id, version.id, @predicate)

      %{
        organization: organization,
        version: version,
        audit: %AuditContext{
          organization_id: organization.id,
          gtfs_version_id: version.id,
          actor_id: actor.id,
          actor_email: actor.email
        },
        prepared: %{
          predicate: @predicate,
          fingerprint: selection.fingerprint,
          stop_ids: Enum.map(selection.stops, & &1.id)
        },
        changes: [
          %{id: stops["A1"].id, from: nil, to: "B"},
          %{id: stops["A3"].id, from: nil, to: "B"}
        ]
      }
    end)
  end

  defp committed_zones(fixture, stop_ids) do
    unboxed(fn ->
      Repo.all(
        from(s in Stop,
          where: s.gtfs_version_id == ^fixture.version.id and s.stop_id in ^stop_ids,
          select: {s.stop_id, s.zone_id}
        )
      )
      |> Map.new()
    end)
  end

  defp cleanup(fixture), do: unboxed(fn -> delete_committed_scope!([fixture.organization.id]) end)
end
