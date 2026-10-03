defmodule GtfsPlanner.Gtfs.Blocking.DeadheadPairsTest do
  @moduledoc """
  The Driving times list shows every ordered pair the day type's blocks drive, and
  one direction at a time can be entered, reset and refused — so a save that stores
  both directions, a reset that leaves a row and an accepted foreign reference stay
  rejected.

  Every case goes through the `Gtfs` facade, which is the path the page's
  `save_driving_times` and `reset_driving_time` use, and the list is read from a
  real day load: nothing here builds a context, a movement or a pair by hand.
  A pair the list shows is a leg the day's own blocks drove.

  The expected minutes are derived independently of the module under test: the
  haversine formula is restated here with the same 6 371 000 m earth radius
  `StationReport2.Helpers.haversine/4` uses, and the minutes are the estimate formula
  over that distance at the version defaults (30 km/h, 1.3 circuity). The four
  points sit on one meridian, so the values are checkable by hand: 0.04° is
  4 448 m and 12 minutes, 0.02° is 2 224 m and 6 minutes.

  Rows are created inside the SQL Sandbox transaction and rolled back. The one
  exception is the lock case, which needs an organization and version another
  connection can see: it commits its own disposable rows on an own connection
  and deletes exactly those rows in `on_exit`, like `settings_test.exs` and
  `route_operating_settings_test.exs`.

  The module is `async: false` because the lock case observes another backend's
  `pg_stat_activity` wait.

  Run with:
  `mix test test/gtfs_planner/gtfs/blocking/deadhead_pairs_test.exs`.
  """
  use GtfsPlanner.DataCase, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias GtfsPlanner.Accounts.{User, UserOrgMembership}
  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.Blocking
  alias GtfsPlanner.Gtfs.DeadheadTime
  alias GtfsPlanner.Gtfs.Stop
  alias GtfsPlanner.Organizations.Organization
  alias GtfsPlanner.Versions
  alias GtfsPlanner.Versions.GtfsVersion

  import GtfsPlanner.AdvancedBlockingFixtures
  import GtfsPlanner.BlockingFixtures
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OperationsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  @moduletag timeout: 120_000

  # The lock case holds one lock open and observes another backend's wait, so it is
  # bounded: a 120 s deadline per test, and a 10 s self-release for a
  # hold the test never gets to release.
  @hold_timeout 10_000
  @receive_timeout 5_000
  @lock_wait_attempts 500
  @task_timeout 15_000

  # The estimate at the version defaults: 30 km/h is 500 m per minute, circuity 1.3.
  @circuity 1.3
  @metres_per_minute 500.0
  @earth_radius_m 6_371_000.0

  # The day's own points, on one meridian, in the order the fixture writes them.
  @main {40.04, -74.0}
  @riverside {40.0, -74.0}
  @valley_college {40.01, -74.0}
  @market_square {40.03, -74.0}

  setup do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    route = route_fixture(organization.id, version.id)

    calendar_service_fixture(organization.id, version.id, %{service_id: "WK", name: "Weekday"})

    # Four stops on one meridian, a hundredth of a degree apart, so every pair of
    # them is a drive rather than a nearby layover. `S4` has no coordinates at
    # all, which is the one leg whose driving time cannot be estimated.
    for {stop_id, name, lat} <- [
          {"S1", "Riverside", "40.0000"},
          {"S2", "Valley College", "40.0100"},
          {"S3", "Market Square", "40.0300"},
          {"S4", "Riverside Yard", nil}
        ] do
      stop_with_coordinates_fixture(organization.id, version.id, %{
        stop_id: stop_id,
        stop_name: name,
        stop_lat: lat && Decimal.new(lat),
        stop_lon: lat && Decimal.new("-74.0")
      })
    end

    main =
      garage_fixture(organization.id, %{
        "name" => "Main",
        "lat" => Decimal.new("40.0400"),
        "lon" => Decimal.new("-74.0")
      })

    %{
      organization: organization,
      version: version,
      route: route,
      main: main
    }
  end

  describe "list_deadhead_pairs/3" do
    test "lists every driven pair with its labels, use count and estimate, most used first",
         context do
      %{organization: organization, version: version, main: main} = context

      planned_day(context)

      assert {:ok, pairs} = Gtfs.list_deadhead_pairs(organization.id, version.id, nil)

      garage_ref = "garage:#{main.id}"

      # Most used first, and within a use count by the labels: "Main" before
      # "Riverside". The estimates are the estimate formula over the fixture's own
      # coordinates, recomputed here rather than asked of the module.
      assert pairs == [
               %{
                 from: garage_ref,
                 to: "stop:S1",
                 from_label: "Main",
                 to_label: "Riverside",
                 uses: 2,
                 minutes: estimated_minutes(@main, @riverside),
                 source: :estimated
               },
               %{
                 from: "stop:S1",
                 to: garage_ref,
                 from_label: "Riverside",
                 to_label: "Main",
                 uses: 2,
                 minutes: estimated_minutes(@riverside, @main),
                 source: :estimated
               },
               %{
                 from: "stop:S4",
                 to: "stop:S1",
                 from_label: "Riverside Yard",
                 to_label: "Riverside",
                 uses: 1,
                 minutes: nil,
                 source: :unknown
               },
               %{
                 from: "stop:S2",
                 to: "stop:S3",
                 from_label: "Valley College",
                 to_label: "Market Square",
                 uses: 1,
                 minutes: estimated_minutes(@valley_college, @market_square),
                 source: :estimated
               }
             ]

      # The hand-checkable values behind those estimates: 0.04° of latitude is
      # about 4 448 m, which is 12 minutes at 500 m per minute with 1.3 circuity.
      assert estimated_minutes(@main, @riverside) == 12
      assert estimated_minutes(@valley_college, @market_square) == 6

      # Every listed pair is a leg of the day, and the two uses of one pair are
      # two blocks' pulls rather than a counted pull and a counted return.
      assert Enum.map(pairs, & &1.uses) == [2, 2, 1, 1]
    end

    test "a day with no block lists nothing, and the entered count is a subset of it", context do
      %{organization: organization, version: version} = context

      assert {:ok, []} = Gtfs.list_deadhead_pairs(organization.id, version.id, nil)

      # An entered value for a pair the day does not drive is stored but listed
      # nowhere: the drawer lists the drives this day type has.
      assert {:ok, _stored} =
               Gtfs.put_deadhead_time(
                 GtfsPlanner.AccountsFixtures.editor_audit_fixture(organization.id, version.id),
                 {"stop:S1", "stop:S3"},
                 4
               )

      assert {:ok, []} = Gtfs.list_deadhead_pairs(organization.id, version.id, nil)
      assert Repo.aggregate(DeadheadTime, :count) == 1
    end

    test "an unknown day type key selects none and another organization is not found", context do
      %{organization: organization, version: version} = context

      planned_day(context)

      {:ok, day} = Gtfs.load_blocking_day(organization.id, version.id, nil)
      [day_type] = day.day_types

      assert {:error, {:unknown_day_type, day_types}} =
               Gtfs.list_deadhead_pairs(organization.id, version.id, "SAT")

      # The derived list is handed back, so a caller can show what exists rather
      # than falling back to another day type.
      assert Enum.map(day_types, & &1.key) == [day_type.key]

      # The derived key itself is the one that answers, and it answers with the
      # same pairs the default key did.
      assert {:ok, pairs} = Gtfs.list_deadhead_pairs(organization.id, version.id, day_type.key)
      assert length(pairs) == 4

      other_organization = organization_fixture()
      foreign_version = gtfs_version_fixture(other_organization.id)

      assert Gtfs.list_deadhead_pairs(organization.id, foreign_version.id, nil) ==
               {:error, :not_found}

      assert Gtfs.put_deadhead_time(
               GtfsPlanner.AccountsFixtures.editor_audit_fixture(
                 organization.id,
                 foreign_version.id
               ),
               {"stop:S1", "stop:S3"},
               4
             ) ==
               {:error, :not_found}

      assert Gtfs.clear_deadhead_time(
               GtfsPlanner.AccountsFixtures.editor_audit_fixture(
                 organization.id,
                 foreign_version.id
               ),
               {"stop:S1", "stop:S3"}
             ) ==
               {:error, :not_found}

      # A staging version of this organization is not found either, and none of
      # those refusals stored anything.
      {:ok, staging} = Versions.create_staging_gtfs_version(organization.id, %{name: "Staging"})

      assert Gtfs.list_deadhead_pairs(organization.id, staging.id, nil) == {:error, :not_found}

      assert Gtfs.put_deadhead_time(
               GtfsPlanner.AccountsFixtures.editor_audit_fixture(organization.id, staging.id),
               {"stop:S1", "stop:S3"},
               4
             ) ==
               {:error, :not_found}

      assert Repo.aggregate(DeadheadTime, :count) == 0
    end
  end

  describe "put_deadhead_time/3" do
    test "stores one row and the list shows the entered value in its own direction", context do
      %{organization: organization, version: version} = context

      planned_day(context)

      assert {:ok, stored} =
               Gtfs.put_deadhead_time(
                 GtfsPlanner.AccountsFixtures.editor_audit_fixture(organization.id, version.id),
                 {"stop:S2", "stop:S3"},
                 9
               )

      assert stored.minutes == 9
      assert stored.organization_id == organization.id
      assert stored.gtfs_version_id == version.id
      assert stored.from_ref == "stop:S2"
      assert stored.to_ref == "stop:S3"

      assert Repo.aggregate(DeadheadTime, :count) == 1

      assert {:ok, pairs} = Gtfs.list_deadhead_pairs(organization.id, version.id, nil)

      # The entered 9 replaces the 6-minute estimate for this direction, and the
      # use count and the labels are untouched: only the minutes and the source
      # answer the save.
      assert pair(pairs, "stop:S2", "stop:S3") == %{
               from: "stop:S2",
               to: "stop:S3",
               from_label: "Valley College",
               to_label: "Market Square",
               uses: 1,
               minutes: 9,
               source: :entered
             }
    end

    test "an entered value never answers the reverse direction and never writes it", context do
      %{organization: organization, version: version, main: main} = context

      planned_day(context)

      assert {:ok, _stored} =
               Gtfs.put_deadhead_time(
                 GtfsPlanner.AccountsFixtures.editor_audit_fixture(organization.id, version.id),
                 {"garage:#{main.id}", "stop:S1"},
                 9
               )

      assert Repo.aggregate(DeadheadTime, :count) == 1

      assert [stored] = Repo.all(DeadheadTime)
      assert stored.from_ref == "garage:#{main.id}"
      assert stored.to_ref == "stop:S1"

      assert {:ok, pairs} = Gtfs.list_deadhead_pairs(organization.id, version.id, nil)

      # Main → Riverside is entered 9; the pull back is the reverse pair and keeps
      # its own estimate, because the estimate is symmetric and the entered value
      # is not.
      assert pair(pairs, "garage:#{main.id}", "stop:S1").minutes == 9
      assert pair(pairs, "garage:#{main.id}", "stop:S1").source == :entered

      assert pair(pairs, "stop:S1", "garage:#{main.id}").minutes == 12
      assert pair(pairs, "stop:S1", "garage:#{main.id}").source == :estimated
    end

    test "a second save replaces the minutes of the same row and the row count holds", context do
      %{organization: organization, version: version} = context

      assert {:ok, first} =
               Gtfs.put_deadhead_time(
                 GtfsPlanner.AccountsFixtures.editor_audit_fixture(organization.id, version.id),
                 {"stop:S1", "stop:S3"},
                 9
               )

      assert {:ok, second} =
               Gtfs.put_deadhead_time(
                 GtfsPlanner.AccountsFixtures.editor_audit_fixture(organization.id, version.id),
                 {"stop:S1", "stop:S3"},
                 0
               )

      assert Repo.aggregate(DeadheadTime, :count) == 1
      assert first.id == second.id
      assert second.minutes == 0
    end

    test "0 is stored as an entered zero rather than read as a missing value", context do
      %{organization: organization, version: version} = context

      planned_day(context)

      assert {:ok, stored} =
               Gtfs.put_deadhead_time(
                 GtfsPlanner.AccountsFixtures.editor_audit_fixture(organization.id, version.id),
                 {"stop:S2", "stop:S3"},
                 0
               )

      assert stored.minutes == 0

      assert {:ok, pairs} = Gtfs.list_deadhead_pairs(organization.id, version.id, nil)

      # A 0 is a real answer — the vehicle is already there — and it never falls
      # through to the estimate the way a missing value would.
      assert %{minutes: 0, source: :entered} = pair(pairs, "stop:S2", "stop:S3")
    end

    test "601, -1 and a non-numeric value are changeset errors and store nothing", context do
      %{organization: organization, version: version} = context

      planned_day(context)

      for minutes <- [601, 1000, -1, "nine", "", nil] do
        assert {:error, %Ecto.Changeset{} = changeset} =
                 Gtfs.put_deadhead_time(
                   GtfsPlanner.AccountsFixtures.editor_audit_fixture(organization.id, version.id),
                   {"stop:S2", "stop:S3"},
                   minutes
                 )

        assert %{minutes: [_message]} = errors_on(changeset)
        assert Repo.aggregate(DeadheadTime, :count) == 0
      end

      # 600 is the largest accepted value, and it is stored.
      assert {:ok, stored} =
               Gtfs.put_deadhead_time(
                 GtfsPlanner.AccountsFixtures.editor_audit_fixture(organization.id, version.id),
                 {"stop:S2", "stop:S3"},
                 600
               )

      assert stored.minutes == 600
      assert Repo.aggregate(DeadheadTime, :count) == 1
    end

    test "a stop of another version, an unknown stop and a foreign garage are :invalid_ref",
         context do
      %{organization: organization, version: version, main: main} = context

      planned_day(context)

      other_organization = organization_fixture()
      other_version = gtfs_version_fixture(organization.id)
      foreign_version = gtfs_version_fixture(other_organization.id)
      foreign_garage = garage_fixture(other_organization.id, %{"name" => "Foreign"})

      # S9 exists, but in another version of this organization.
      stop_with_coordinates_fixture(organization.id, other_version.id, %{
        stop_id: "S9",
        stop_name: "Other version",
        stop_lat: Decimal.new("41.0"),
        stop_lon: Decimal.new("-74.0")
      })

      # And a stop of another organization's version is just as unknown here.
      stop_with_coordinates_fixture(other_organization.id, foreign_version.id, %{
        stop_id: "S8",
        stop_name: "Foreign",
        stop_lat: Decimal.new("41.0"),
        stop_lon: Decimal.new("-74.0")
      })

      invalid = [
        {"stop:S9", "stop:S1"},
        {"stop:S1", "stop:S9"},
        {"stop:S8", "stop:S1"},
        {"garage:#{foreign_garage.id}", "stop:S1"},
        {"stop:S1", "garage:#{foreign_garage.id}"},
        {"garage:#{Ecto.UUID.generate()}", "stop:S1"},
        # A correctable public `garage_id` is not a reference.
        {"garage:#{main.garage_id}", "stop:S1"},
        # And neither is a hand-edited or empty reference.
        {"garage:not-a-uuid", "stop:S1"},
        {"bus:1", "stop:S1"},
        {"stop:", "stop:S1"},
        {"S1", "S2"}
      ]

      for {from_ref, to_ref} <- invalid do
        assert Gtfs.put_deadhead_time(
                 GtfsPlanner.AccountsFixtures.editor_audit_fixture(organization.id, version.id),
                 {from_ref, to_ref},
                 9
               ) ==
                 {:error, :invalid_ref}
      end

      assert Repo.aggregate(DeadheadTime, :count) == 0

      # The same pair with a garage of this organization is accepted, so the
      # refusals above are the ownership and the stored form, not the shape.
      assert {:ok, _stored} =
               Gtfs.put_deadhead_time(
                 GtfsPlanner.AccountsFixtures.editor_audit_fixture(organization.id, version.id),
                 {"garage:#{main.id}", "stop:S1"},
                 9
               )

      assert Repo.aggregate(DeadheadTime, :count) == 1
    end
  end

  describe "clear_deadhead_time/2" do
    test "removes the row so the pair shows its estimate again, and only that direction",
         context do
      %{organization: organization, version: version, main: main} = context

      planned_day(context)

      assert {:ok, _forward} =
               Gtfs.put_deadhead_time(
                 GtfsPlanner.AccountsFixtures.editor_audit_fixture(organization.id, version.id),
                 {"stop:S2", "stop:S3"},
                 9
               )

      assert {:ok, _reverse} =
               Gtfs.put_deadhead_time(
                 GtfsPlanner.AccountsFixtures.editor_audit_fixture(organization.id, version.id),
                 {"stop:S3", "stop:S2"},
                 30
               )

      assert Repo.aggregate(DeadheadTime, :count) == 2

      assert :ok =
               Gtfs.clear_deadhead_time(
                 GtfsPlanner.AccountsFixtures.editor_audit_fixture(organization.id, version.id),
                 {"stop:S2", "stop:S3"}
               )

      assert Repo.aggregate(DeadheadTime, :count) == 1

      assert [stored] = Repo.all(DeadheadTime)
      assert stored.from_ref == "stop:S3"
      assert stored.to_ref == "stop:S2"
      assert stored.minutes == 30

      assert {:ok, pairs} = Gtfs.list_deadhead_pairs(organization.id, version.id, nil)

      # The cleared direction is estimated again and keeps its use count; the
      # reverse is untouched.
      assert pair(pairs, "stop:S2", "stop:S3") == %{
               from: "stop:S2",
               to: "stop:S3",
               from_label: "Valley College",
               to_label: "Market Square",
               uses: 1,
               minutes: 6,
               source: :estimated
             }

      assert pair(pairs, "stop:S1", "garage:#{main.id}").minutes == 12
    end

    test "clearing a pair with no stored row is :not_found and changes nothing", context do
      %{organization: organization, version: version} = context

      planned_day(context)

      assert Gtfs.clear_deadhead_time(
               GtfsPlanner.AccountsFixtures.editor_audit_fixture(organization.id, version.id),
               {"stop:S2", "stop:S3"}
             ) ==
               {:error, :not_found}

      assert Repo.aggregate(DeadheadTime, :count) == 0

      # A ref that never decoded matches no row either, and is not found rather
      # than raised.
      assert Gtfs.clear_deadhead_time(
               GtfsPlanner.AccountsFixtures.editor_audit_fixture(organization.id, version.id),
               {"bus:1", "stop:S1"}
             ) ==
               {:error, :not_found}
    end

    test "a clear after a clear is :not_found rather than an error the planner must ignore",
         context do
      %{organization: organization, version: version} = context

      assert {:ok, _stored} =
               Gtfs.put_deadhead_time(
                 GtfsPlanner.AccountsFixtures.editor_audit_fixture(organization.id, version.id),
                 {"stop:S1", "stop:S3"},
                 9
               )

      assert :ok =
               Gtfs.clear_deadhead_time(
                 GtfsPlanner.AccountsFixtures.editor_audit_fixture(organization.id, version.id),
                 {"stop:S1", "stop:S3"}
               )

      assert Gtfs.clear_deadhead_time(
               GtfsPlanner.AccountsFixtures.editor_audit_fixture(organization.id, version.id),
               {"stop:S1", "stop:S3"}
             ) ==
               {:error, :not_found}

      assert Repo.aggregate(DeadheadTime, :count) == 0
    end
  end

  describe "put_deadhead_time/3 and clear_deadhead_time/2 under a held blocking lock" do
    test "both writers wait for lock_blocking!1 and succeed after the release" do
      scope =
        unboxed(fn ->
          organization = organization_fixture()
          version = gtfs_version_fixture(organization.id)

          stop_with_coordinates_fixture(organization.id, version.id, %{
            stop_id: "S1",
            stop_name: "Riverside",
            stop_lat: Decimal.new("40.0000"),
            stop_lon: Decimal.new("-74.0")
          })

          stop_with_coordinates_fixture(organization.id, version.id, %{
            stop_id: "S3",
            stop_name: "Market Square",
            stop_lat: Decimal.new("40.0300"),
            stop_lon: Decimal.new("-74.0")
          })

          %{organization_id: organization.id, version_id: version.id}
        end)

      on_exit(fn -> cleanup_committed_scope(scope) end)

      parent = self()

      # The save waits for the lock, and stores once the holder releases it.
      holder = Task.async(fn -> hold_blocking_lock(scope, parent) end)
      assert_receive :blocking_lock_held, @receive_timeout

      writer =
        Task.async(fn ->
          unboxed(fn ->
            {:ok, %{rows: [[backend_pid]]}} = Repo.query("select pg_backend_pid()")
            send(parent, {:writer_pid, backend_pid})

            Blocking.put_deadhead_time(
              GtfsPlanner.AccountsFixtures.editor_audit_fixture(
                scope.organization_id,
                scope.version_id
              ),
              {"stop:S1", "stop:S3"},
              9
            )
          end)
        end)

      assert_receive {:writer_pid, writer_pid}, @receive_timeout
      assert wait_until_locked(writer_pid)

      send(holder.pid, :release)
      Task.await(holder, @task_timeout)
      assert {:ok, %DeadheadTime{minutes: 9}} = Task.await(writer, @task_timeout)

      # The reset takes the same lock, and returns once the holder releases it.
      holder = Task.async(fn -> hold_blocking_lock(scope, parent) end)
      assert_receive :blocking_lock_held, @receive_timeout

      resetter =
        Task.async(fn ->
          unboxed(fn ->
            {:ok, %{rows: [[backend_pid]]}} = Repo.query("select pg_backend_pid()")
            send(parent, {:resetter_pid, backend_pid})

            Blocking.clear_deadhead_time(
              GtfsPlanner.AccountsFixtures.editor_audit_fixture(
                scope.organization_id,
                scope.version_id
              ),
              {"stop:S1", "stop:S3"}
            )
          end)
        end)

      assert_receive {:resetter_pid, resetter_pid}, @receive_timeout
      assert wait_until_locked(resetter_pid)

      send(holder.pid, :release)
      Task.await(holder, @task_timeout)
      assert :ok = Task.await(resetter, @task_timeout)

      assert unboxed(fn ->
               Repo.aggregate(DeadheadTime, :count, organization_id: scope.organization_id)
             end) == 0
    end
  end

  describe "a stop changes while a deadhead save waits for its reference" do
    for action <- [:rename, :delete] do
      test "a concurrent #{action} makes the old natural stop reference invalid" do
        scope =
          unboxed(fn ->
            organization = organization_fixture()
            version = gtfs_version_fixture(organization.id)

            source =
              stop_with_coordinates_fixture(organization.id, version.id, %{
                stop_id: "S1",
                stop_name: "Riverside",
                stop_lat: Decimal.new("40.0000"),
                stop_lon: Decimal.new("-74.0")
              })

            stop_with_coordinates_fixture(organization.id, version.id, %{
              stop_id: "S3",
              stop_name: "Market Square",
              stop_lat: Decimal.new("40.0300"),
              stop_lon: Decimal.new("-74.0")
            })

            %{
              organization_id: organization.id,
              version_id: version.id,
              source_id: source.id,
              audit:
                GtfsPlanner.AccountsFixtures.editor_audit_fixture(organization.id, version.id)
            }
          end)

        on_exit(fn -> cleanup_committed_scope(scope) end)
        parent = self()
        supervisor = start_supervised!({Task.Supervisor, []})

        holder =
          Task.Supervisor.async_nolink(supervisor, fn ->
            unboxed(fn ->
              Repo.transaction(fn ->
                Repo.one!(from(s in Stop, where: s.id == ^scope.source_id, lock: "FOR UPDATE"))
                send(parent, :stop_reference_held)

                receive do
                  :release -> :ok
                after
                  @hold_timeout -> Repo.rollback(:timeout)
                end

                case unquote(action) do
                  :rename ->
                    Repo.update_all(from(s in Stop, where: s.id == ^scope.source_id),
                      set: [stop_id: "S1_RENAMED"]
                    )

                  :delete ->
                    Repo.delete_all(from(s in Stop, where: s.id == ^scope.source_id))
                end
              end)
            end)
          end)

        assert_receive :stop_reference_held, @receive_timeout

        writer =
          Task.Supervisor.async_nolink(supervisor, fn ->
            unboxed(fn ->
              {:ok, %{rows: [[backend_pid]]}} = Repo.query("select pg_backend_pid()")
              send(parent, {:reference_writer_pid, backend_pid})

              Gtfs.put_deadhead_time(scope.audit, {"stop:S1", "stop:S3"}, 9)
            end)
          end)

        assert_receive {:reference_writer_pid, writer_pid}, @receive_timeout
        assert wait_until_locked(writer_pid)

        send(holder.pid, :release)
        assert {:ok, {_count, _}} = Task.await(holder, @task_timeout)
        assert {:error, :invalid_ref} = Task.await(writer, @task_timeout)

        assert unboxed(fn ->
                 Repo.aggregate(DeadheadTime, :count, organization_id: scope.organization_id)
               end) == 0
      end
    end
  end

  # The day the list cases read: 101 and 102 pull out of Main and come back, so
  # each direction of the Main ↔ Riverside pair is driven twice; 103 drives
  # Valley College → Market Square once; and 104 drives a pair whose origin has no
  # coordinates, so its drive is unknown rather than zero.
  defp planned_day(context) do
    %{organization: organization, version: version, main: main} = context

    for block_id <- ["101", "102"] do
      block_attribute_fixture(organization.id, version.id, %{
        service_id: "WK",
        block_id: block_id,
        garage_id: main.id
      })
    end

    trip!(context, "a", "101", "05:50:00", "06:50:00", "S1", "S1")
    trip!(context, "b", "102", "07:00:00", "08:00:00", "S1", "S1")
    trip!(context, "c", "103", "09:00:00", "09:30:00", "S2", "S2")
    trip!(context, "d", "103", "10:30:00", "11:00:00", "S3", "S3")
    trip!(context, "e", "104", "12:00:00", "12:30:00", "S1", "S4")
    trip!(context, "f", "104", "13:00:00", "13:30:00", "S1", "S1")
  end

  # One trip from `first_stop` at `first` to `last_stop` at `last`, so a case can
  # name the endpoints that make the handoff a drive.
  defp trip!(context, trip_id, block_id, first, last, first_stop, last_stop) do
    %{organization: organization, version: version, route: route} = context

    trip =
      trip_fixture(organization.id, version.id, route.route_id, %{
        trip_id: trip_id,
        service_id: "WK",
        block_id: block_id
      })

    stop_time_fixture(organization.id, version.id, trip_id, first_stop, %{
      stop_sequence: 1,
      arrival_time: first,
      departure_time: first
    })

    stop_time_fixture(organization.id, version.id, trip_id, last_stop, %{
      stop_sequence: 2,
      arrival_time: last,
      departure_time: last
    })

    trip
  end

  defp pair(pairs, from_ref, to_ref),
    do: Enum.find(pairs, &(&1.from == from_ref and &1.to == to_ref))

  # The estimate formula over a distance computed here, so the expected minutes never
  # come from the module under test.
  defp estimated_minutes(from, to) do
    round(haversine_m(from, to) * @circuity / @metres_per_minute)
  end

  # The haversine formula, restated here so the expected distance is derived
  # independently of `StationReport2.Helpers.haversine/4`.
  defp haversine_m({lat1, lon1}, {lat2, lon2}) do
    dlat = to_radians(lat2 - lat1)
    dlon = to_radians(lon2 - lon1)

    a =
      :math.sin(dlat / 2) * :math.sin(dlat / 2) +
        :math.cos(to_radians(lat1)) * :math.cos(to_radians(lat2)) * :math.sin(dlon / 2) *
          :math.sin(dlon / 2)

    a = min(max(a, 0.0), 1.0)

    2 * :math.atan2(:math.sqrt(a), :math.sqrt(1 - a)) * @earth_radius_m
  end

  defp to_radians(degrees), do: degrees * :math.pi() / 180

  defp unboxed(fun), do: Sandbox.unboxed_run(Repo, fun)

  # Holds the version's blocking lock on an own connection, with the statement
  # `Blocking.lock_blocking!/1` issues, until the test releases it.
  defp hold_blocking_lock(scope, parent) do
    unboxed(fn ->
      Repo.transaction(fn ->
        Repo.query!("SELECT pg_advisory_xact_lock(hashtext($1))", [
          "blocking:" <> scope.version_id
        ])

        send(parent, :blocking_lock_held)

        receive do
          :release -> :ok
        after
          @hold_timeout -> Repo.rollback(:timeout)
        end
      end)
    end)
  end

  # Deletes exactly the rows the lock case committed, keyed to their own organization,
  # on an own connection so the deletion is not part of the sandboxed test transaction.
  # The version's stop rows cascade, so the whole scope goes with it.
  defp cleanup_committed_scope(scope) do
    unboxed(fn ->
      actor_ids =
        Repo.all(
          from(m in UserOrgMembership,
            where: m.organization_id == ^scope.organization_id,
            select: m.user_id
          )
        )

      Repo.delete_all(
        from(m in UserOrgMembership, where: m.organization_id == ^scope.organization_id)
      )

      Repo.delete_all(
        from(s in GtfsPlanner.Gtfs.Stop, where: s.organization_id == ^scope.organization_id)
      )

      delete_versions!(from(v in GtfsVersion, where: v.organization_id == ^scope.organization_id))
      Repo.delete_all(from(o in Organization, where: o.id == ^scope.organization_id))
      Repo.delete_all(from(u in User, where: u.id in ^actor_ids))
    end)
  end

  defp wait_until_locked(pid, attempts \\ @lock_wait_attempts) do
    {:ok, %{rows: [[waiting]]}} =
      Repo.query(
        "select count(*) from pg_stat_activity where pid = $1 and wait_event_type = 'Lock'",
        [pid]
      )

    cond do
      waiting > 0 ->
        true

      attempts <= 0 ->
        flunk("the backend #{inspect(pid)} never waited on a lock")

      true ->
        Process.sleep(10)
        wait_until_locked(pid, attempts - 1)
    end
  end
end
