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
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias Ecto.Adapters.SQL.Sandbox
  alias GtfsPlanner.Accounts.User
  alias GtfsPlanner.Accounts.UserOrgMembership
  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.Agency
  alias GtfsPlanner.Gtfs.AuditContext
  alias GtfsPlanner.Gtfs.Calendar
  alias GtfsPlanner.Gtfs.CalendarAttribute
  alias GtfsPlanner.Gtfs.CalendarDate
  alias GtfsPlanner.Gtfs.Calendars
  alias GtfsPlanner.Gtfs.ChangeLog
  alias GtfsPlanner.Gtfs.Pathway
  alias GtfsPlanner.Gtfs.Route
  alias GtfsPlanner.Gtfs.RoutePattern
  alias GtfsPlanner.Gtfs.RoutePatternStop
  alias GtfsPlanner.Gtfs.Stop
  alias GtfsPlanner.Gtfs.StopTime
  alias GtfsPlanner.Gtfs.TimedPattern
  alias GtfsPlanner.Gtfs.TimedPatternStop
  alias GtfsPlanner.Gtfs.Transfer
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

  describe "schedule callers" do
    test "a schedule caller completes while another session holds the version share lock",
         %{supervisor: supervisor} do
      scope = seed_schedule_scope("share")
      on_exit(fn -> cleanup_schedule_scope(scope) end)

      # Another session already holds the organization's version row `FOR SHARE`, exactly as a
      # concurrent calendar read or schedule writer does while it works.
      {share_holder, _holder_backend} = hold_shared_version(scope, supervisor)

      # The real schedule caller takes the same share lock first, then the route, pattern, trip and
      # stop-time locks. An upgraded (exclusive) version lock would refuse this second holder, so a
      # bounded lock timeout turns any upgrade into a loud failure instead of a hang.
      assert {:ok, %{trips: [created]}} =
               unboxed(fn ->
                 Repo.transaction(fn ->
                   Repo.query!("SET LOCAL lock_timeout = '3s'")

                   {:ok, result} =
                     Gtfs.create_trips(scope.route_id, create_attrs(scope), scope.audit)

                   result
                 end)
               end)

      # The other session held its share lock for the whole call.
      assert Process.alive?(share_holder.pid)

      assert created.trip_id == "#{scope.route_id}-0-#{scope.service}-0700"
      assert unboxed(fn -> trip_ids(scope) end) == [created.trip_id]

      assert unboxed(fn -> stop_time_clocks(scope, created.trip_id) end) == [
               {"A", "07:00:00", "07:00:00"},
               {"B", "07:05:00", "07:05:30"}
             ]

      send(share_holder.pid, :release)
      assert Task.await(share_holder, @collect_timeout) == {:error, :released}
    end

    test "a schedule caller waiting on the route row holds only the shared version lock",
         %{supervisor: supervisor} do
      scope = seed_schedule_scope("route-wait")
      on_exit(fn -> cleanup_schedule_scope(scope) end)

      {route_holder, route_backend} = hold_route_row(scope, supervisor)

      {caller, caller_backend} =
        start_writer(supervisor, fn ->
          Gtfs.create_trips(scope.route_id, create_attrs(scope), scope.audit)
        end)

      send(caller.pid, :go)

      # The caller reached the route lock, which it can only do after the version boundary.
      assert_blocked_by(caller_backend, route_backend)

      # A concurrent share request still succeeds while it waits on the route...
      assert {:ok, %GtfsVersion{}} = share_lock_version(scope)

      # ...and an exclusive request is refused, so the waiting caller does hold the version row,
      # in share mode rather than in an upgraded exclusive one.
      assert {:error, %Postgrex.Error{postgres: %{code: :lock_not_available}}} =
               exclusive_lock_version(scope)

      send(route_holder.pid, :release)
      assert Task.await(route_holder, @collect_timeout) == {:error, :released}

      assert {:ok, %{trips: [created]}} = Task.await(caller, @collect_timeout)
      assert created.trip_id == "#{scope.route_id}-0-#{scope.service}-0700"
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

  describe "stop writers" do
    test "a parent coordinate update and a previously absent parent insert wait behind the lock",
         %{supervisor: supervisor} do
      scope = seed_scope("stop-parent")
      on_exit(fn -> cleanup([scope.organization.id]) end)

      parent =
        unboxed(fn ->
          stop_fixture(scope.organization.id, scope.version.id, %{
            stop_id: "PARENT_GEOMETRY",
            location_type: 1,
            stop_lat: Decimal.new("40.0"),
            stop_lon: Decimal.new("-74.0")
          })
        end)

      {holder, holder_backend} = hold_exclusive_version(scope, supervisor)

      {update_writer, update_backend} =
        start_writer(supervisor, fn ->
          Gtfs.update_stop(parent, %{stop_lat: "41.5", stop_lon: "-73.5"})
        end)

      {insert_writer, insert_backend} =
        start_writer(supervisor, fn ->
          Gtfs.create_stop(
            stop_attrs(scope, "PARENT_ADDED", %{
              location_type: 1,
              stop_lat: "42.0",
              stop_lon: "-71.0"
            })
          )
        end)

      send(update_writer.pid, :go)
      send(insert_writer.pid, :go)

      assert_blocked_by(update_backend, holder_backend)
      assert_blocked_by(insert_backend, holder_backend)

      # While the version is exclusively owned, neither the projected coordinate nor the parent
      # row that was previously absent is visible.
      assert coordinates?(stop_coordinates(scope, "PARENT_GEOMETRY"), "40.0", "-74.0")
      assert stop_ids(scope) == ["PARENT_GEOMETRY"]

      send(holder.pid, :release)
      assert Task.await(holder, @collect_timeout) == {:error, :released}

      assert {:ok, %Stop{stop_lat: updated_lat}} = Task.await(update_writer, @collect_timeout)
      assert Decimal.equal?(updated_lat, Decimal.new("41.5"))
      assert {:ok, %Stop{stop_id: "PARENT_ADDED"}} = Task.await(insert_writer, @collect_timeout)

      assert coordinates?(stop_coordinates(scope, "PARENT_GEOMETRY"), "41.5", "-73.5")
      assert stop_ids(scope) == ["PARENT_ADDED", "PARENT_GEOMETRY"]
    end

    test "a stop naming an absent parent waits before its phantom becomes visible",
         %{supervisor: supervisor} do
      scope = seed_scope("stop-phantom")
      on_exit(fn -> cleanup([scope.organization.id]) end)

      {holder, holder_backend} = hold_exclusive_version(scope, supervisor)

      {writer, backend} =
        start_writer(supervisor, fn ->
          Gtfs.create_stop(
            stop_attrs(scope, "PHANTOM_CHILD", %{
              parent_station: "ABSENT_PARENT",
              level_id: "L_ABSENT"
            })
          )
        end)

      send(writer.pid, :go)
      assert_blocked_by(backend, holder_backend)

      # Neither the referencing stop nor its parent row exists yet, so the parent-coordinate
      # fallback the projection loads cannot change while the version is owned.
      assert stop_ids(scope) == []
      assert stops_named(scope, "ABSENT_PARENT") == []

      send(holder.pid, :release)
      assert Task.await(holder, @collect_timeout) == {:error, :released}

      assert {:ok, %Stop{stop_id: "PHANTOM_CHILD", parent_station: "ABSENT_PARENT"}} =
               Task.await(writer, @collect_timeout)

      # The referencing stop now exists; the parent row stays absent, exactly the absence the
      # review fingerprint records.
      assert stop_ids(scope) == ["PHANTOM_CHILD"]
      assert stops_named(scope, "ABSENT_PARENT") == []
    end

    test "a stop delete waits behind the lock, removes the row, and releases the version",
         %{supervisor: supervisor} do
      scope = seed_scope("stop-delete")
      on_exit(fn -> cleanup([scope.organization.id]) end)

      stop =
        unboxed(fn ->
          stop_fixture(scope.organization.id, scope.version.id, %{stop_id: "STOP_TO_DELETE"})
        end)

      {holder, holder_backend} = hold_exclusive_version(scope, supervisor)

      {writer, backend} =
        start_writer(supervisor, fn -> Gtfs.delete_stop(stop) end)

      send(writer.pid, :go)
      assert_blocked_by(backend, holder_backend)
      assert stop_ids(scope) == ["STOP_TO_DELETE"]

      send(holder.pid, :release)
      assert Task.await(holder, @collect_timeout) == {:error, :released}

      assert {:ok, %Stop{stop_id: "STOP_TO_DELETE"}} = Task.await(writer, @collect_timeout)
      assert stop_ids(scope) == []

      # The delete committed and released its share lock, so an exclusive version owner can now
      # take the row.
      assert {:ok, %GtfsVersion{}} = exclusive_lock_version(scope)
    end

    test "a stop-ID cascade waits behind the lock and then rewrites every reference",
         %{supervisor: supervisor} do
      scope = seed_scope("stop-cascade")
      on_exit(fn -> cleanup([scope.organization.id]) end)

      {station, stop_time, transfer} =
        unboxed(fn ->
          station =
            stop_fixture(scope.organization.id, scope.version.id, %{
              stop_id: "CASCADE_STATION",
              location_type: 1
            })

          stop_fixture(scope.organization.id, scope.version.id, %{
            stop_id: "CASCADE_CHILD",
            parent_station: "CASCADE_STATION",
            level_id: "L1"
          })

          stop_time =
            stop_time_fixture(
              scope.organization.id,
              scope.version.id,
              "trip_cascade",
              "CASCADE_STATION"
            )

          transfer =
            transfer_fixture(scope.organization.id, scope.version.id, %{
              from_stop_id: "CASCADE_STATION",
              to_stop_id: "CASCADE_CHILD"
            })

          {station, stop_time, transfer}
        end)

      {holder, holder_backend} = hold_exclusive_version(scope, supervisor)

      {writer, backend} =
        start_writer(supervisor, fn ->
          Gtfs.update_stop_with_cascade(station, %{stop_id: "CASCADE_STATION_RENAMED"})
        end)

      send(writer.pid, :go)
      assert_blocked_by(backend, holder_backend)

      # No stop row, stop time, transfer or parent reference is rewritten while the version is
      # exclusively owned.
      assert stop_ids(scope) == ["CASCADE_CHILD", "CASCADE_STATION"]
      assert child_parent_stations(scope) == ["CASCADE_STATION"]
      assert stop_time_stop_ids(scope) == ["CASCADE_STATION"]
      assert transfer_stop_ids(scope) == [{"CASCADE_STATION", "CASCADE_CHILD"}]

      send(holder.pid, :release)
      assert Task.await(holder, @collect_timeout) == {:error, :released}

      assert {:ok, %Stop{stop_id: "CASCADE_STATION_RENAMED"}} =
               Task.await(writer, @collect_timeout)

      # The linked rows keep pointing at the renamed stop through stop_id itself, so their
      # identities and their existing stop-time rows survive the cascade.
      assert stop_ids(scope) == ["CASCADE_CHILD", "CASCADE_STATION_RENAMED"]
      assert child_parent_stations(scope) == ["CASCADE_STATION_RENAMED"]
      assert stop_time_stop_ids(scope) == ["CASCADE_STATION_RENAMED"]
      assert transfer_stop_ids(scope) == [{"CASCADE_STATION_RENAMED", "CASCADE_CHILD"}]

      assert unboxed(fn -> Repo.get!(StopTime, stop_time.id).stop_id end) ==
               "CASCADE_STATION_RENAMED"

      assert unboxed(fn -> Repo.get!(Transfer, transfer.id).from_stop_id end) ==
               "CASCADE_STATION_RENAMED"
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

  # -- Stop writer fixtures and lock probes ----------------------------------

  defp stop_attrs(scope, stop_id, overrides) do
    Map.merge(
      %{
        organization_id: scope.organization.id,
        gtfs_version_id: scope.version.id,
        stop_id: stop_id,
        stop_name: "Stop #{stop_id}",
        location_type: 0,
        wheelchair_boarding: 0
      },
      Map.new(overrides)
    )
  end

  defp stop_ids(scope) do
    unboxed(fn ->
      from(s in Stop,
        where:
          s.organization_id == ^scope.organization.id and
            s.gtfs_version_id == ^scope.version.id,
        order_by: s.stop_id,
        select: s.stop_id
      )
      |> Repo.all()
    end)
  end

  defp stops_named(scope, stop_id) do
    unboxed(fn ->
      from(s in Stop,
        where:
          s.organization_id == ^scope.organization.id and
            s.gtfs_version_id == ^scope.version.id and s.stop_id == ^stop_id,
        select: s.id
      )
      |> Repo.all()
    end)
  end

  defp stop_coordinates(scope, stop_id) do
    unboxed(fn ->
      from(s in Stop,
        where:
          s.organization_id == ^scope.organization.id and
            s.gtfs_version_id == ^scope.version.id and s.stop_id == ^stop_id,
        select: {s.stop_lat, s.stop_lon}
      )
      |> Repo.one()
    end)
  end

  defp coordinates?(coordinates, lat, lon) do
    {actual_lat, actual_lon} = coordinates
    Decimal.equal?(actual_lat, Decimal.new(lat)) and Decimal.equal?(actual_lon, Decimal.new(lon))
  end

  defp child_parent_stations(scope) do
    unboxed(fn ->
      from(s in Stop,
        where:
          s.organization_id == ^scope.organization.id and
            s.gtfs_version_id == ^scope.version.id and not is_nil(s.parent_station),
        order_by: s.stop_id,
        select: s.parent_station
      )
      |> Repo.all()
    end)
  end

  defp stop_time_stop_ids(scope) do
    unboxed(fn ->
      from(st in StopTime,
        where:
          st.organization_id == ^scope.organization.id and
            st.gtfs_version_id == ^scope.version.id,
        order_by: st.stop_sequence,
        select: st.stop_id
      )
      |> Repo.all()
    end)
  end

  defp transfer_stop_ids(scope) do
    unboxed(fn ->
      from(t in Transfer,
        where:
          t.organization_id == ^scope.organization.id and t.gtfs_version_id == ^scope.version.id,
        select: {t.from_stop_id, t.to_stop_id}
      )
      |> Repo.all()
    end)
  end

  defp cleanup(organization_ids) do
    unboxed(fn ->
      Repo.delete_all(from(t in Transfer, where: t.organization_id in ^organization_ids))
      Repo.delete_all(from(p in Pathway, where: p.organization_id in ^organization_ids))
      Repo.delete_all(from(s in Stop, where: s.organization_id in ^organization_ids))
      Repo.delete_all(from(t in Trip, where: t.organization_id in ^organization_ids))
      Repo.delete_all(from(s in StopTime, where: s.organization_id in ^organization_ids))
      Repo.delete_all(from(a in Agency, where: a.organization_id in ^organization_ids))
      Repo.delete_all(from(v in GtfsVersion, where: v.organization_id in ^organization_ids))
      Repo.delete_all(from(o in Organization, where: o.id in ^organization_ids))

      refute Repo.exists?(from(s in Stop, where: s.organization_id in ^organization_ids))
      refute Repo.exists?(from(t in Trip, where: t.organization_id in ^organization_ids))
      refute Repo.exists?(from(v in GtfsVersion, where: v.organization_id in ^organization_ids))
      refute Repo.exists?(from(o in Organization, where: o.id in ^organization_ids))
      :ok
    end)
  end

  defp unboxed(fun), do: Sandbox.unboxed_run(Repo, fun)

  # -- Schedule caller fixtures and lock probes -------------------------------

  # One committed schedule scope: an organization with its published version, one route, one
  # calendar identity the caller references, and one two-stop pattern with a timing whose offsets
  # the caller materializes.
  defp seed_schedule_scope(suffix) do
    unboxed(fn ->
      unique = "#{System.system_time(:millisecond)}-#{System.unique_integer([:positive])}"

      organization =
        organization_fixture(%{alias: "input-writer-schedule-#{suffix}-#{unique}"})

      version = gtfs_version_fixture(organization.id)
      route_id = "sc#{System.unique_integer([:positive])}"
      route = route_fixture(organization.id, version.id, %{route_id: route_id})
      service = "svc_#{unique}"
      calendar_fixture(organization.id, version.id, %{service_id: service})

      actor = user_fixture()

      audit = %AuditContext{
        organization_id: organization.id,
        gtfs_version_id: version.id,
        actor_id: actor.id,
        actor_email: actor.email
      }

      bundle =
        schedule_pattern_fixture(organization.id, version.id, %{
          route_id: route_id,
          route_pattern_id: "SC-#{unique}",
          direction_id: 0,
          stops: [{"A", 0, 0, 1}, {"B", 300, 330, 1}]
        })

      %{
        organization: organization,
        version: version,
        route: route,
        route_id: route_id,
        service: service,
        actor: actor,
        audit: audit,
        bundle: bundle
      }
    end)
  end

  defp create_attrs(scope) do
    %{
      pattern_id: scope.bundle.pattern.id,
      timed_pattern_id: scope.bundle.timing.id,
      service_id: scope.service,
      start_time: "07:00:00",
      repeat: nil
    }
  end

  defp stop_time_clocks(scope, trip_id) do
    unboxed(fn ->
      Repo.all(
        from(st in StopTime,
          where: st.organization_id == ^scope.organization.id and st.trip_id == ^trip_id,
          order_by: [asc: st.stop_sequence, asc: st.id],
          select: {st.stop_id, st.arrival_time, st.departure_time}
        )
      )
    end)
  end

  defp hold_shared_version(scope, supervisor) do
    parent = self()

    holder =
      Task.Supervisor.async_nolink(supervisor, fn -> hold_shared_until_released(scope, parent) end)

    assert_receive {:version_shared, holder_pid, holder_backend}, @contention_timeout
    assert holder_pid == holder.pid
    {holder, holder_backend}
  end

  defp hold_shared_until_released(scope, parent) do
    unboxed(fn ->
      Repo.transaction(fn ->
        Versions.lock_for_input_write!(scope.organization.id, scope.version.id)
        send(parent, {:version_shared, self(), backend_pid()})

        receive do
          :release -> Repo.rollback(:released)
        end
      end)
    end)
  end

  defp hold_route_row(scope, supervisor) do
    parent = self()

    holder =
      Task.Supervisor.async_nolink(supervisor, fn -> hold_route_until_released(scope, parent) end)

    assert_receive {:route_held, holder_pid, holder_backend}, @contention_timeout
    assert holder_pid == holder.pid
    {holder, holder_backend}
  end

  defp hold_route_until_released(scope, parent) do
    unboxed(fn ->
      Repo.transaction(fn ->
        Repo.one(from(r in Route, where: r.id == ^scope.route.id, lock: "FOR UPDATE"))
        send(parent, {:route_held, self(), backend_pid()})

        receive do
          :release -> Repo.rollback(:released)
        end
      end)
    end)
  end

  defp share_lock_version(scope) do
    unboxed(fn ->
      Repo.transaction(fn ->
        Repo.query!("SET LOCAL lock_timeout = '3s'")

        Repo.one(
          from(v in GtfsVersion,
            where: v.id == ^scope.version.id and v.organization_id == ^scope.organization.id,
            lock: "FOR SHARE"
          )
        )
      end)
    end)
  end

  # The probe reports the refusal whether the adapter returns the error tuple or re-raises it.
  defp exclusive_lock_version(scope) do
    unboxed(fn ->
      Repo.transaction(fn ->
        Repo.query!("SET LOCAL lock_timeout = '1s'")

        Repo.one(
          from(v in GtfsVersion,
            where: v.id == ^scope.version.id and v.organization_id == ^scope.organization.id,
            lock: "FOR UPDATE"
          )
        )
      end)
    end)
  rescue
    error in Postgrex.Error -> {:error, error}
  end

  defp cleanup_schedule_scope(scope) do
    unboxed(fn ->
      organization_id = scope.organization.id

      Repo.delete_all(from(l in ChangeLog, where: l.organization_id == ^organization_id))
      Repo.delete_all(from(st in StopTime, where: st.organization_id == ^organization_id))
      Repo.delete_all(from(t in Trip, where: t.organization_id == ^organization_id))

      Repo.delete_all(
        from(r in TimedPatternStop,
          where:
            r.timed_pattern_id in subquery(
              from(t in TimedPattern, where: t.organization_id == ^organization_id, select: t.id)
            )
        )
      )

      Repo.delete_all(from(t in TimedPattern, where: t.organization_id == ^organization_id))
      Repo.delete_all(from(o in RoutePatternStop, where: o.organization_id == ^organization_id))
      Repo.delete_all(from(p in RoutePattern, where: p.organization_id == ^organization_id))

      Repo.delete_all(from(a in CalendarAttribute, where: a.organization_id == ^organization_id))

      Repo.delete_all(from(d in CalendarDate, where: d.organization_id == ^organization_id))
      Repo.delete_all(from(c in Calendar, where: c.organization_id == ^organization_id))
      Repo.delete_all(from(r in Route, where: r.organization_id == ^organization_id))

      Repo.delete_all(
        from(m in UserOrgMembership,
          where: m.organization_id == ^organization_id or m.user_id == ^scope.actor.id
        )
      )

      Repo.delete_all(from(v in GtfsVersion, where: v.organization_id == ^organization_id))
      Repo.delete_all(from(u in User, where: u.id == ^scope.actor.id))
      Repo.delete_all(from(o in Organization, where: o.id == ^organization_id))

      refute Repo.exists?(from(o in Organization, where: o.id == ^organization_id))
      refute Repo.exists?(from(v in GtfsVersion, where: v.organization_id == ^organization_id))
      refute Repo.exists?(from(l in ChangeLog, where: l.organization_id == ^organization_id))
      :ok
    end)
  end
end
