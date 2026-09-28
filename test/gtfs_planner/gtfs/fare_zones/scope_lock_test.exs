defmodule GtfsPlanner.Gtfs.FareZones.ScopeLockTest do
  @moduledoc """
  Merge evidence (EV-7) for the published-version-row lock on assignment writes.

  Two separately committing sessions are used (`Sandbox.unboxed_run/2`), never one
  shared sandbox connection: one holds `SELECT … FOR UPDATE` on the version row
  while `apply_assignment/3` runs in another process, so the writer's wait is a
  real row lock and its result is observed after the holder commits. The second
  case races two writers of the same reviewed change, so the lock plus the stale
  fence must let exactly one of them commit.

  The test is deliberately not `async: true`; it creates a unique organization and
  deletes every row it commits on exit.
  """
  use ExUnit.Case

  import Ecto.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias GtfsPlanner.Gtfs.FareZone
  alias GtfsPlanner.Gtfs.FareZones
  alias GtfsPlanner.Gtfs.Stop
  alias GtfsPlanner.Organizations.Organization
  alias GtfsPlanner.OrganizationsFixtures
  alias GtfsPlanner.Repo
  alias GtfsPlanner.Versions.GtfsVersion
  alias GtfsPlanner.VersionsFixtures

  test "a session holding the version row blocks apply_assignment until it commits" do
    supervisor = start_supervised!({Task.Supervisor, name: __MODULE__.TaskSupervisor})
    fixture = committed_fixture("lock")
    on_exit(fn -> cleanup(fixture) end)

    parent = self()

    holder =
      Task.Supervisor.async_nolink(supervisor, fn ->
        unboxed(fn ->
          Repo.transaction(fn ->
            locked =
              Repo.one(
                from(v in GtfsVersion,
                  where:
                    v.id == ^fixture.version.id and
                      v.organization_id == ^fixture.organization.id,
                  lock: "FOR UPDATE"
                )
              )

            send(parent, {:locked, locked.id})

            receive do
              :release -> :released
            end
          end)
        end)
      end)

    assert_receive {:locked, version_id}, 5_000
    assert version_id == fixture.version.id

    changes = [%{id: fixture.stop.id, from: nil, to: "A"}]

    writer =
      Task.Supervisor.async_nolink(supervisor, fn ->
        send(parent, {:writer_started, System.monotonic_time()})

        unboxed(fn ->
          FareZones.apply_assignment(fixture.organization.id, fixture.version.id, changes)
        end)
      end)

    assert_receive {:writer_started, _}, 5_000

    assert Task.yield(writer, 200) == nil

    assert committed_zone(fixture.stop.id) == nil

    send(holder.pid, :release)

    assert Task.await(holder, 10_000) == {:ok, :released}

    assert {:ok, %{applied: [%{id: id, from: nil, to: "A"}]}} = Task.await(writer, 10_000)
    assert id == fixture.stop.id
    assert committed_zone(fixture.stop.id) == "A"
  end

  test "two writers of the same reviewed change serialize and only one commits" do
    supervisor = start_supervised!({Task.Supervisor, name: __MODULE__.TaskSupervisor})
    fixture = committed_fixture("race")
    on_exit(fn -> cleanup(fixture) end)

    changes = [%{id: fixture.stop.id, from: nil, to: "A"}]

    results =
      1..2
      |> Enum.map(fn _index ->
        Task.Supervisor.async_nolink(supervisor, fn ->
          unboxed(fn ->
            FareZones.apply_assignment(fixture.organization.id, fixture.version.id, changes)
          end)
        end)
      end)
      |> Enum.map(&Task.await(&1, 10_000))

    assert {:ok, %{applied: [%{id: id, from: nil, to: "A"}]}} =
             Enum.find(results, &match?({:ok, _}, &1))

    assert id == fixture.stop.id

    assert {:error, {:stale, [%{id: stale_id, reviewed: nil, current: "A"}]}} =
             Enum.find(results, &match?({:error, {:stale, _}}, &1))

    assert stale_id == fixture.stop.id
    assert committed_zone(fixture.stop.id) == "A"
  end

  defp committed_fixture(suffix) do
    unboxed(fn ->
      organization =
        OrganizationsFixtures.organization_fixture(%{
          alias: "fare-zones-lock-#{suffix}-#{System.system_time(:nanosecond)}"
        })

      version = VersionsFixtures.gtfs_version_fixture(organization.id)
      now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

      stop_id = Ecto.UUID.generate()

      {1, nil} =
        Repo.insert_all(Stop, [
          %{
            id: stop_id,
            organization_id: organization.id,
            gtfs_version_id: version.id,
            stop_id: "lock-1",
            stop_name: "Locked stop",
            location_type: 0,
            zone_id: nil,
            inserted_at: now,
            updated_at: now
          }
        ])

      {1, nil} =
        Repo.insert_all(FareZone, [
          %{
            id: Ecto.UUID.generate(),
            organization_id: organization.id,
            gtfs_version_id: version.id,
            zone_id: "A",
            name: "Declared A",
            color: "ocean",
            inserted_at: now,
            updated_at: now
          }
        ])

      %{organization: organization, version: version, stop: %{id: stop_id}}
    end)
  end

  defp committed_zone(stop_id), do: unboxed(fn -> Repo.get!(Stop, stop_id).zone_id end)

  defp cleanup(fixture) do
    unboxed(fn ->
      organization_id = fixture.organization.id

      Repo.delete_all(from(z in FareZone, where: z.organization_id == ^organization_id))
      Repo.delete_all(from(s in Stop, where: s.organization_id == ^organization_id))
      Repo.delete_all(from(v in GtfsVersion, where: v.organization_id == ^organization_id))
      Repo.delete_all(from(o in Organization, where: o.id == ^organization_id))

      refute Repo.exists?(from(o in Organization, where: o.id == ^organization_id))
      refute Repo.exists?(from(v in GtfsVersion, where: v.organization_id == ^organization_id))
      refute Repo.exists?(from(s in Stop, where: s.organization_id == ^organization_id))
      refute Repo.exists?(from(z in FareZone, where: z.organization_id == ^organization_id))
    end)
  end

  defp unboxed(fun), do: Sandbox.unboxed_run(Repo, fun)
end
