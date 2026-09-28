defmodule GtfsPlanner.Gtfs.Calendars.InputWriterConcurrencyTest do
  # AC-15/AC-16: `Gtfs.create_trip/1`, `Gtfs.create_stop_time/1` and `Gtfs.create_agency/1`
  # must take the scoped version share lock before their insert, so a calendar change that
  # owns the same version row `FOR UPDATE` cannot commit a reviewed input between a review
  # load and its apply. A staging scope keeps writing because `Versions.lock_for_input_write!/2`
  # is a scoped row lock, not an authorization check.
  #
  # `async: false` plus `Sandbox.unboxed_run/2` gives every participant its own committing
  # PostgreSQL connection. Contention is proven by polling `pg_blocking_pids/1` for the
  # holder's own backend until the writer is genuinely waiting, so no timing sleep is the
  # proof, while the parent connection reads the rows that must not exist yet.
  #
  # The focused gate command is deferred to branch review:
  # `mix test test/gtfs_planner/gtfs/calendars/input_writer_concurrency_test.exs`.
  use ExUnit.Case, async: false

  import Ecto.Query
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias Ecto.Adapters.SQL.Sandbox
  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.Agency
  alias GtfsPlanner.Gtfs.Calendars
  alias GtfsPlanner.Gtfs.StopTime
  alias GtfsPlanner.Gtfs.Trip
  alias GtfsPlanner.Organizations.Organization
  alias GtfsPlanner.Repo
  alias GtfsPlanner.Versions
  alias GtfsPlanner.Versions.GtfsVersion

  @collect_timeout 15_000
  @contention_timeout 10_000
  @poll_interval 10

  setup do
    supervisor = start_supervised!({Task.Supervisor, name: __MODULE__.TaskSupervisor})
    %{supervisor: supervisor}
  end

  describe "Versions.lock_for_input_write!/2" do
    test "locks the scoped version row and reports a foreign or unknown scope as :not_found" do
      scope = seed_scope("lock")
      other = seed_scope("lock-other")
      on_exit(fn -> cleanup([scope.organization.id, other.organization.id]) end)

      assert {:ok, %GtfsVersion{} = locked} =
               lock_scope(scope.organization.id, scope.version.id)

      assert locked.id == scope.version.id
      assert locked.organization_id == scope.organization.id

      # The lock is not an authorization check: an unpublished import scope is locked too.
      assert {:ok, %GtfsVersion{publication_status: "staging"}} =
               lock_scope(scope.organization.id, scope.staging_version.id)

      assert {:error, :not_found} = lock_scope(scope.organization.id, other.version.id)
      assert {:error, :not_found} = lock_scope(scope.organization.id, Ecto.UUID.generate())
      assert {:error, :not_found} = lock_scope(nil, nil)
    end

    test "calendar reads and schedule writers keep their own published requirement" do
      scope = seed_scope("published")
      on_exit(fn -> cleanup([scope.organization.id]) end)

      assert {:ok, _calendars} =
               unboxed(fn ->
                 Calendars.list_calendars(scope.organization.id, scope.version.id)
               end)

      assert {:error, :not_found} =
               unboxed(fn ->
                 Calendars.list_calendars(scope.organization.id, scope.staging_version.id)
               end)
    end
  end

  describe "direct input writers" do
    test "an exclusive version holder blocks create_trip and create_stop_time until it releases",
         %{supervisor: supervisor} do
      scope = seed_scope("blocked")
      on_exit(fn -> cleanup([scope.organization.id]) end)

      {holder, holder_backend} = hold_exclusive_version(scope, supervisor)

      {trip_writer, trip_backend} =
        start_writer(supervisor, fn -> Gtfs.create_trip(trip_attrs(scope, "BLOCKED_TRIP")) end)

      {stop_time_writer, stop_time_backend} =
        start_writer(supervisor, fn -> Gtfs.create_stop_time(stop_time_attrs(scope, 1)) end)

      send(trip_writer.pid, :go)
      send(stop_time_writer.pid, :go)

      assert_blocked_by(trip_backend, holder_backend)
      assert_blocked_by(stop_time_backend, holder_backend)

      # Nothing was written while the version was exclusively owned, even though the
      # writers had already issued their inserts.
      assert trip_ids(scope) == []
      assert stop_time_ids(scope) == []

      send(holder.pid, :release)
      assert Task.await(holder, @collect_timeout) == {:error, :released}

      assert {:ok, %Trip{trip_id: "BLOCKED_TRIP"}} = Task.await(trip_writer, @collect_timeout)
      assert {:ok, %StopTime{}} = Task.await(stop_time_writer, @collect_timeout)

      assert trip_ids(scope) == ["BLOCKED_TRIP"]
      assert length(stop_time_ids(scope)) == 1
    end

    test "an agency that would change the display zone waits behind the exclusive version lock",
         %{supervisor: supervisor} do
      scope = seed_scope("agency")
      on_exit(fn -> cleanup([scope.organization.id]) end)

      # No agency yet: the review's display clock falls back to UTC.
      assert %{timezone: "UTC", fallback?: true, fallback_reason: :missing} =
               unboxed(fn ->
                 Gtfs.resolve_display_zone(scope.organization.id, scope.version.id)
               end)

      {holder, holder_backend} = hold_exclusive_version(scope, supervisor)

      {writer, backend} =
        start_writer(supervisor, fn ->
          Gtfs.create_agency(agency_attrs(scope, "America/New_York"))
        end)

      send(writer.pid, :go)
      assert_blocked_by(backend, holder_backend)

      # The zone the review loaded cannot change while the version lock is held.
      assert %{timezone: "UTC", fallback?: true} =
               unboxed(fn ->
                 Gtfs.resolve_display_zone(scope.organization.id, scope.version.id)
               end)

      send(holder.pid, :release)
      assert Task.await(holder, @collect_timeout) == {:error, :released}
      assert {:ok, %Agency{}} = Task.await(writer, @collect_timeout)

      assert %{timezone: "America/New_York", fallback?: false} =
               unboxed(fn ->
                 Gtfs.resolve_display_zone(scope.organization.id, scope.version.id)
               end)
    end

    test "an independent organization writes while another version is locked and a foreign scope is refused",
         %{supervisor: supervisor} do
      first = seed_scope("independent-first")
      second = seed_scope("independent-second")
      on_exit(fn -> cleanup([first.organization.id, second.organization.id]) end)

      {holder, holder_backend} = hold_exclusive_version(first, supervisor)

      {blocked_writer, blocked_backend} =
        start_writer(supervisor, fn -> Gtfs.create_trip(trip_attrs(first, "WAITING_TRIP")) end)

      send(blocked_writer.pid, :go)
      assert_blocked_by(blocked_backend, holder_backend)

      # The independent scope is not serialized by the first organization's exclusive lock.
      assert {:ok, %Trip{trip_id: "INDEPENDENT_TRIP"}} =
               unboxed(fn -> Gtfs.create_trip(trip_attrs(second, "INDEPENDENT_TRIP")) end)

      send(holder.pid, :release)
      assert Task.await(holder, @collect_timeout) == {:error, :released}
      assert {:ok, %Trip{trip_id: "WAITING_TRIP"}} = Task.await(blocked_writer, @collect_timeout)

      # A scope pairing one organization with another organization's version is refused.
      assert {:error, :not_found} =
               unboxed(fn ->
                 Gtfs.create_trip(
                   trip_attrs(first, "FOREIGN_TRIP", %{
                     organization_id: second.organization.id
                   })
                 )
               end)

      assert {:error, :not_found} =
               unboxed(fn ->
                 Gtfs.create_stop_time(
                   stop_time_attrs(first, 9, %{organization_id: second.organization.id})
                 )
               end)

      refute unboxed(fn ->
               Repo.exists?(
                 from(t in Trip,
                   where:
                     t.organization_id == ^second.organization.id and
                       t.gtfs_version_id == ^first.version.id
                 )
               )
             end)
    end

    test "a staging import scope keeps its permitted writes", %{supervisor: supervisor} do
      scope = seed_scope("staging")
      on_exit(fn -> cleanup([scope.organization.id]) end)

      # The organization's published version is exclusively owned, as a calendar change
      # would own it; the staging version is a different row and stays writable.
      {holder, _holder_backend} = hold_exclusive_version(scope, supervisor)

      assert {:ok, %Trip{trip_id: "STAGING_TRIP"}} =
               unboxed(fn ->
                 Gtfs.create_trip(
                   trip_attrs(scope, "STAGING_TRIP", %{gtfs_version_id: scope.staging_version.id})
                 )
               end)

      assert {:ok, %StopTime{}} =
               unboxed(fn ->
                 Gtfs.create_stop_time(
                   stop_time_attrs(scope, 2, %{gtfs_version_id: scope.staging_version.id})
                 )
               end)

      assert {:ok, %Agency{}} =
               unboxed(fn ->
                 Gtfs.create_agency(
                   agency_attrs(scope, "Europe/Berlin", %{
                     gtfs_version_id: scope.staging_version.id
                   })
                 )
               end)

      send(holder.pid, :release)
      assert Task.await(holder, @collect_timeout) == {:error, :released}

      # Publication rules are unchanged by the writer path: the scope is still unpublished.
      assert %GtfsVersion{publication_status: "staging", published_at: nil} =
               unboxed(fn ->
                 Repo.get!(GtfsVersion, scope.staging_version.id)
               end)
    end
  end

  describe "writer return shapes" do
    test "invalid input keeps the changeset error without requiring a scope or a connection" do
      assert {:error, %Ecto.Changeset{valid?: false}} = Gtfs.create_trip(%{})
      assert {:error, %Ecto.Changeset{valid?: false}} = Gtfs.create_stop_time(%{})
      assert {:error, %Ecto.Changeset{valid?: false}} = Gtfs.create_agency(%{})
    end

    test "a refused duplicate insert releases the version lock for the next writer" do
      scope = seed_scope("duplicate")
      on_exit(fn -> cleanup([scope.organization.id]) end)

      assert {:ok, %Trip{}} = unboxed(fn -> Gtfs.create_trip(trip_attrs(scope, "DUP")) end)

      assert {:error, %Ecto.Changeset{errors: errors}} =
               unboxed(fn -> Gtfs.create_trip(trip_attrs(scope, "DUP")) end)

      # Ecto reports the three-column unique constraint on its first field.
      assert {"has already been taken", opts} = errors[:organization_id]

      assert opts[:constraint_name] == "trips_organization_id_gtfs_version_id_trip_id_index"

      assert {:ok, %Trip{trip_id: "AFTER"}} =
               unboxed(fn -> Gtfs.create_trip(trip_attrs(scope, "AFTER")) end)

      # The refused insert rolled its transaction back, so the version row is free again.
      assert {:ok, :acquired} =
               unboxed(fn ->
                 Repo.transaction(fn ->
                   Repo.query!("SET LOCAL lock_timeout = '5s'")

                   Repo.one(
                     from(v in GtfsVersion,
                       where: v.id == ^scope.version.id,
                       lock: "FOR UPDATE"
                     )
                   )

                   :acquired
                 end)
               end)
    end
  end

  # Releases the writer into real contention for the version row while an independent
  # session owns it exclusively, and verifies the writer really waits on that session.
  defp hold_exclusive_version(scope, supervisor) do
    parent = self()

    holder =
      Task.Supervisor.async_nolink(supervisor, fn -> hold_version(scope, parent) end)

    assert_receive {:version_held, holder_pid, holder_backend}, @contention_timeout
    assert holder_pid == holder.pid
    {holder, holder_backend}
  end

  defp hold_version(scope, parent) do
    unboxed(fn -> Repo.transaction(fn -> lock_version_until_released(scope, parent) end) end)
  end

  defp lock_version_until_released(scope, parent) do
    Repo.one(
      from(v in GtfsVersion,
        where: v.id == ^scope.version.id and v.organization_id == ^scope.organization.id,
        lock: "FOR UPDATE"
      )
    )

    send(parent, {:version_held, self(), backend_pid()})

    receive do
      :release -> Repo.rollback(:released)
    end
  end

  defp start_writer(supervisor, run) do
    parent = self()

    writer =
      Task.Supervisor.async_nolink(supervisor, fn ->
        unboxed(fn ->
          backend = backend_pid()
          send(parent, {:writer_ready, self(), backend})

          receive do
            :go -> :ok
          end

          run.()
        end)
      end)

    assert_receive {:writer_ready, writer_pid, backend}, @contention_timeout
    assert writer_pid == writer.pid
    {writer, backend}
  end

  defp assert_blocked_by(backend, holder_backend) do
    deadline = System.monotonic_time(:millisecond) + @contention_timeout

    case unboxed(fn -> await_blocker(backend, holder_backend, deadline) end) do
      :ok ->
        :ok

      {:error, blocked_by} ->
        flunk(
          "expected backend #{backend} to wait on #{holder_backend}, saw blocking pids #{inspect(blocked_by)}"
        )
    end
  end

  defp await_blocker(backend, holder_backend, deadline) do
    blocked_by = blockers_of(backend)

    cond do
      holder_backend in blocked_by ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        {:error, blocked_by}

      true ->
        Process.sleep(@poll_interval)
        await_blocker(backend, holder_backend, deadline)
    end
  end

  defp blockers_of(backend) do
    %Postgrex.Result{rows: [[blockers]]} = Repo.query!("SELECT pg_blocking_pids($1)", [backend])
    List.wrap(blockers)
  end

  defp backend_pid do
    %Postgrex.Result{rows: [[backend]]} = Repo.query!("SELECT pg_backend_pid()")
    backend
  end

  defp lock_scope(organization_id, version_id) do
    unboxed(fn ->
      Repo.transaction(fn -> Versions.lock_for_input_write!(organization_id, version_id) end)
    end)
  end

  defp seed_scope(suffix) do
    unboxed(fn ->
      unique = "#{System.system_time(:millisecond)}-#{System.unique_integer([:positive])}"

      organization = organization_fixture(%{alias: "input-writer-#{suffix}-#{unique}"})
      version = gtfs_version_fixture(organization.id)

      {:ok, staging_version} =
        Versions.create_staging_gtfs_version(organization.id, %{name: "Staging #{unique}"})

      %{
        organization: organization,
        version: version,
        staging_version: staging_version
      }
    end)
  end

  defp trip_attrs(scope, trip_id, overrides \\ %{}) do
    Map.merge(
      %{
        organization_id: scope.organization.id,
        gtfs_version_id: scope.version.id,
        route_id: "route_input_writer",
        trip_id: trip_id,
        service_id: "service_input_writer"
      },
      Map.new(overrides)
    )
  end

  defp stop_time_attrs(scope, stop_sequence, overrides \\ %{}) do
    Map.merge(
      %{
        organization_id: scope.organization.id,
        gtfs_version_id: scope.version.id,
        trip_id: "trip_input_writer",
        stop_id: "stop_input_writer",
        stop_sequence: stop_sequence,
        arrival_time: "08:00:00",
        departure_time: "08:00:00"
      },
      Map.new(overrides)
    )
  end

  defp agency_attrs(scope, timezone, overrides \\ %{}) do
    Map.merge(
      %{
        organization_id: scope.organization.id,
        gtfs_version_id: scope.version.id,
        agency_id: "agency_input_writer",
        agency_name: "Input Writer Transit",
        agency_url: "https://example.test",
        agency_timezone: timezone
      },
      Map.new(overrides)
    )
  end

  defp trip_ids(scope) do
    unboxed(fn ->
      from(t in Trip,
        where:
          t.organization_id == ^scope.organization.id and
            t.gtfs_version_id == ^scope.version.id,
        order_by: t.trip_id,
        select: t.trip_id
      )
      |> Repo.all()
    end)
  end

  defp stop_time_ids(scope) do
    unboxed(fn ->
      from(s in StopTime,
        where:
          s.organization_id == ^scope.organization.id and
            s.gtfs_version_id == ^scope.version.id,
        order_by: s.stop_sequence,
        select: s.id
      )
      |> Repo.all()
    end)
  end

  defp cleanup(organization_ids) do
    unboxed(fn ->
      Repo.delete_all(from(t in Trip, where: t.organization_id in ^organization_ids))
      Repo.delete_all(from(s in StopTime, where: s.organization_id in ^organization_ids))
      Repo.delete_all(from(a in Agency, where: a.organization_id in ^organization_ids))
      Repo.delete_all(from(v in GtfsVersion, where: v.organization_id in ^organization_ids))
      Repo.delete_all(from(o in Organization, where: o.id in ^organization_ids))

      refute Repo.exists?(from(t in Trip, where: t.organization_id in ^organization_ids))
      refute Repo.exists?(from(v in GtfsVersion, where: v.organization_id in ^organization_ids))
      refute Repo.exists?(from(o in Organization, where: o.id in ^organization_ids))
      :ok
    end)
  end

  defp unboxed(fun), do: Sandbox.unboxed_run(Repo, fun)
end
