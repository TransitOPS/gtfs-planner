defmodule GtfsPlanner.Gtfs.Blocking.ReliefSettingsTest do
  @moduledoc """
  Merge evidence (EV-20) for CL-20: the Operator changes drawer lists the places
  the day type's own trips start and end — grouped under a parent station, with
  the number of feasible waits at each — and one save stores the relief limit and
  exactly the ticked candidates among them, so FH-20's two failures stay
  rejected.

  Every case goes through the `Gtfs` facade, which is the path step 41's
  `save_operator_changes` uses, and both the list and the writer read the day
  through the same `Blocking.read_day/3` the page holds: nothing here builds a
  context, a movement or a candidate by hand. A candidate in this list is a place
  the day really has a wait at.

  The fixture's coordinates are on one meridian a hundredth of a degree apart, so
  a handoff between two of them is a move beyond 200 m and a handoff within one
  station is a layover. The expected wait counts are read off the day's own
  movements rather than restated here: what each case pins is which candidate a
  gap's wait is charged to, which is the rule under test.

  Rows are created inside the SQL Sandbox transaction and rolled back. The one
  exception is the lock case, which needs an organization and version another
  connection can see: it commits its own disposable rows on an own connection
  and deletes exactly those rows in `on_exit`, like `deadhead_pairs_test.exs`.

  The module is `async: false` because the lock case observes another backend's
  `pg_stat_activity` wait.

  The focused gate command is deferred to branch review:
  `mix test test/gtfs_planner/gtfs/blocking/relief_settings_test.exs`.
  """
  use GtfsPlanner.DataCase, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.Blocking
  alias GtfsPlanner.Gtfs.BlockingSetting
  alias GtfsPlanner.Gtfs.ReliefPoint
  alias GtfsPlanner.Organizations.Organization
  alias GtfsPlanner.Versions
  alias GtfsPlanner.Versions.GtfsVersion

  import GtfsPlanner.AdvancedBlockingFixtures
  import GtfsPlanner.BlockingFixtures
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  @moduletag timeout: 120_000

  # The lock case holds one lock open and observes another backend's wait, so it is
  # bounded: EV-20's 120 s command deadline per test, and a 10 s self-release for a
  # hold the test never gets to release.
  @hold_timeout 10_000
  @receive_timeout 5_000
  @lock_wait_attempts 500
  @task_timeout 15_000

  # 0.02 degrees of latitude is about 2 224 m, so every handoff between two of the
  # fixture's stops is a move rather than a nearby layover, and a handoff between
  # two stops of one station is a layover because `Checks.handoff/2` reads the
  # parent station.
  @riverside {40.0, -74.0}
  @valley_college {40.01, -74.0}
  @market_square {40.03, -74.0}

  setup do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    route = route_fixture(organization.id, version.id)

    calendar_service_fixture(organization.id, version.id, %{service_id: "WK", name: "Weekday"})

    # The station is a row of its own so the list can name it, and the two bays
    # carry no coordinates of their own: they inherit the station's, exactly as a
    # real feed's child stops do.
    stop_with_coordinates_fixture(organization.id, version.id, %{
      stop_id: "RIV",
      stop_name: "Riverside Station",
      stop_lat: Decimal.new("#{@riverside |> elem(0)}"),
      stop_lon: Decimal.new("#{@riverside |> elem(1)}")
    })

    for {stop_id, name, parent, {lat, lon}} <- [
          {"BAY_A", "Bay A", "RIV", @riverside},
          {"BAY_B", "Bay B", "RIV", @riverside},
          {"VC", "Valley College", nil, @valley_college},
          {"MS", "Market Square", nil, @market_square}
        ] do
      stop_with_coordinates_fixture(organization.id, version.id, %{
        stop_id: stop_id,
        stop_name: name,
        parent_station: parent,
        stop_lat: Decimal.new("#{lat}"),
        stop_lon: Decimal.new("#{lon}")
      })
    end

    %{
      organization: organization,
      version: version,
      route: route
    }
  end

  describe "list_relief_candidates/3" do
    test "one candidate per place, stations grouped, most waits first", context do
      %{organization: organization, version: version} = context

      planned_day(context)

      assert {:ok, candidates} = Gtfs.list_relief_candidates(organization.id, version.id, nil)

      # Two layovers inside Riverside Station are two waits at one candidate, and
      # the station reads by its own name with its two bays named beneath it. The
      # Valley College → Market Square drive is R5's two windows, one wait at each
      # end, so the two stops tie on one wait each and the name decides the order.
      assert candidates == [
               %{
                 stop_id: "RIV",
                 name: "Riverside Station",
                 station?: true,
                 child_names: ["Bay A", "Bay B"],
                 waits: 2,
                 marked?: false
               },
               %{
                 stop_id: "MS",
                 name: "Market Square",
                 station?: false,
                 child_names: [],
                 waits: 1,
                 marked?: false
               },
               %{
                 stop_id: "VC",
                 name: "Valley College",
                 station?: false,
                 child_names: [],
                 waits: 1,
                 marked?: false
               }
             ]

      # Each wait is a real gap of the day's own movements, counted where the
      # vehicle stands: block 101's layover is at Bay A, block 102's drive waits at
      # both of its ends, and block 103's layover is at Bay A again.
      {:ok, day} = Gtfs.load_blocking_day(organization.id, version.id, nil)

      assert Enum.map(day.blocks, & &1.summary.block_id) == ["101", "102", "103"]

      gaps =
        for block <- day.blocks,
            gap <- block.movements.gaps,
            do: {gap.kind, gap.feasible?, gap.wait_secs}

      assert gaps == [
               {:layover, true, 600},
               {:drive, true, 3240},
               {:layover, true, 1800}
             ]
    end

    test "an infeasible gap, an unknown drive and a stop no trip touches count for nobody",
         context do
      %{organization: organization, version: version} = context

      planned_day(context)

      # Block 104 hands over from the yard, which carries no coordinates of its own
      # or of a parent, so its drive is unknown rather than zero. Block 105 leaves
      # one minute for a drive that needs six, so it is infeasible. Neither is a
      # place a change can be planned into, and the yard stop becomes a candidate
      # with no waits rather than one with a made-up count.
      stop_with_coordinates_fixture(organization.id, version.id, %{
        stop_id: "YARD",
        stop_name: "Riverside Yard",
        stop_lat: nil,
        stop_lon: nil
      })

      trip!(context, "g", "104", "14:00:00", "14:30:00", "MS", "YARD")
      trip!(context, "h", "104", "14:35:00", "15:05:00", "VC", "VC")
      trip!(context, "i", "105", "16:00:00", "16:01:00", "MS", "MS")
      trip!(context, "j", "105", "16:02:00", "16:30:00", "VC", "VC")

      assert {:ok, candidates} = Gtfs.list_relief_candidates(organization.id, version.id, nil)

      # The three candidates from the planned day keep their counts, and the two
      # unusable gaps added nothing to either of their ends.
      assert candidate(candidates, "RIV").waits == 2
      assert candidate(candidates, "MS").waits == 1
      assert candidate(candidates, "VC").waits == 1

      assert candidate(candidates, "YARD") == %{
               stop_id: "YARD",
               name: "Riverside Yard",
               station?: false,
               child_names: [],
               waits: 0,
               marked?: false
             }
    end

    test "a stored mark shows on the candidate it names, and only on that one", context do
      %{organization: organization, version: version} = context

      planned_day(context)

      relief_point_fixture(organization.id, version.id, %{stop_id: "VC"})

      assert {:ok, candidates} = Gtfs.list_relief_candidates(organization.id, version.id, nil)

      assert candidate(candidates, "VC").marked?
      refute candidate(candidates, "MS").marked?
      refute candidate(candidates, "RIV").marked?
    end

    test "an unknown day type key selects none and another organization is not found", context do
      %{organization: organization, version: version} = context

      planned_day(context)

      assert {:error, {:unknown_day_type, day_types}} =
               Gtfs.list_relief_candidates(organization.id, version.id, "SAT")

      {:ok, day} = Gtfs.load_blocking_day(organization.id, version.id, nil)
      [day_type] = day.day_types
      assert Enum.map(day_types, & &1.key) == [day_type.key]

      # The derived key itself answers, and with the same candidates (INV-6).
      assert {:ok, candidates} =
               Gtfs.list_relief_candidates(organization.id, version.id, day_type.key)

      assert length(candidates) == 3

      other_organization = organization_fixture()
      foreign_version = gtfs_version_fixture(other_organization.id)

      assert Gtfs.list_relief_candidates(organization.id, foreign_version.id, nil) ==
               {:error, :not_found}

      {:ok, staging} = Versions.create_staging_gtfs_version(organization.id, %{name: "Staging"})

      assert Gtfs.list_relief_candidates(organization.id, staging.id, nil) == {:error, :not_found}
    end
  end

  describe "update_relief_settings/4" do
    test "stores the limit and the ticked candidates, and a later save unticks", context do
      %{organization: organization, version: version} = context

      planned_day(context)

      assert {:ok, :ok} =
               Gtfs.update_relief_settings(organization.id, version.id, nil, %{
                 max_piece_minutes: 330,
                 marked: ["RIV"]
               })

      # The limit is stored on the shared settings row, and only that column moved:
      # the seven settings the Block rules drawer owns keep their defaults.
      assert [setting] = Repo.all(BlockingSetting)
      assert setting.max_piece_minutes == 330
      assert setting.min_layover_minutes == 5
      assert setting.interlining == :any
      assert setting.default_garage_id == nil

      assert [stored] = Repo.all(ReliefPoint)
      assert stored.stop_id == "RIV"
      assert stored.organization_id == organization.id
      assert stored.gtfs_version_id == version.id

      assert {:ok, candidates} = Gtfs.list_relief_candidates(organization.id, version.id, nil)
      assert candidate(candidates, "RIV").marked?
      refute candidate(candidates, "VC").marked?

      # A later save with no ticks deletes the row rather than leaving it, and the
      # limit is still the one this save carries.
      assert {:ok, :ok} =
               Gtfs.update_relief_settings(organization.id, version.id, nil, %{
                 max_piece_minutes: 300,
                 marked: []
               })

      assert Repo.aggregate(ReliefPoint, :count) == 0
      assert [setting] = Repo.all(BlockingSetting)
      assert setting.max_piece_minutes == 300
      # One row, replaced rather than duplicated.
      assert Repo.aggregate(BlockingSetting, :count) == 1
    end

    test "the limit save leaves the other seven settings exactly as they were", context do
      %{organization: organization, version: version} = context

      planned_day(context)

      # The Block rules drawer writes first, through its own facade. It answers the
      # stored row rather than `:ok`, which is why this case matches on the row.
      assert {:ok, %BlockingSetting{} = stored} =
               Gtfs.update_blocking_settings(organization.id, version.id, %{
                 "min_layover_minutes" => "8",
                 "pull_out_buffer_minutes" => "4",
                 "interlining" => "same_stop",
                 "deadhead_speed_kmh" => "40",
                 "deadhead_circuity" => "1.4"
               })

      assert stored.min_layover_minutes == 8
      assert stored.max_piece_minutes == nil

      assert {:ok, :ok} =
               Gtfs.update_relief_settings(organization.id, version.id, nil, %{
                 max_piece_minutes: 330,
                 marked: ["RIV"]
               })

      settings = Gtfs.get_blocking_settings(organization.id, version.id)

      assert settings.max_piece_minutes == 330
      assert settings.min_layover_minutes == 8
      assert settings.pull_out_buffer_minutes == 4
      assert settings.interlining == :same_stop
      assert settings.deadhead_speed_kmh == 40
      assert settings.deadhead_circuity == 1.4
      assert settings.max_block_minutes == nil
    end

    test "a mark outside the day's candidates survives a save that omits it", context do
      %{organization: organization, version: version} = context

      planned_day(context)

      # `S9` is a stop of the version that no trip of this day type touches, so it
      # is not a candidate and the save must not touch its mark.
      stop_with_coordinates_fixture(organization.id, version.id, %{
        stop_id: "S9",
        stop_name: "Depot",
        stop_lat: Decimal.new("40.05"),
        stop_lon: Decimal.new("-74.0")
      })

      relief_point_fixture(organization.id, version.id, %{stop_id: "S9"})

      assert {:ok, :ok} =
               Gtfs.update_relief_settings(organization.id, version.id, nil, %{
                 max_piece_minutes: 330,
                 marked: ["RIV"]
               })

      assert Enum.map(Repo.all(ReliefPoint), & &1.stop_id) |> Enum.sort() == ["RIV", "S9"]

      # And the second save, which unticks RIV, still leaves the outside mark alone.
      assert {:ok, :ok} =
               Gtfs.update_relief_settings(organization.id, version.id, nil, %{
                 max_piece_minutes: 330,
                 marked: []
               })

      assert Enum.map(Repo.all(ReliefPoint), & &1.stop_id) == ["S9"]
    end

    test "an ID in marked that is not a candidate of this day type is ignored", context do
      %{organization: organization, version: version} = context

      planned_day(context)

      # "BAY_A" is a real stop, but the candidate it belongs to is its station, and
      # "NOPE" is nothing at all. Neither is stored; "RIV" is.
      assert {:ok, :ok} =
               Gtfs.update_relief_settings(organization.id, version.id, nil, %{
                 max_piece_minutes: 330,
                 marked: ["RIV", "BAY_A", "NOPE"]
               })

      assert Enum.map(Repo.all(ReliefPoint), & &1.stop_id) == ["RIV"]
    end

    test "59 and 721 are changeset errors that store nothing, and a blank stores nil", context do
      %{organization: organization, version: version} = context

      planned_day(context)

      for limit <- [59, 721, 0, -1, "nine"] do
        assert {:error, %Ecto.Changeset{} = changeset} =
                 Gtfs.update_relief_settings(organization.id, version.id, nil, %{
                   max_piece_minutes: limit,
                   marked: ["RIV"]
                 })

        assert %{max_piece_minutes: [_message]} = errors_on(changeset)

        # Nothing at all was written: no limit and no mark.
        assert Repo.aggregate(BlockingSetting, :count) == 0
        assert Repo.aggregate(ReliefPoint, :count) == 0
      end

      # 60 and 720 are the ends of the accepted range, and a blank is "no limit".
      for limit <- [60, 720, nil, ""] do
        assert {:ok, :ok} =
                 Gtfs.update_relief_settings(organization.id, version.id, nil, %{
                   max_piece_minutes: limit,
                   marked: ["RIV"]
                 })

        assert [setting] = Repo.all(BlockingSetting)
        assert setting.max_piece_minutes == if(limit in [nil, ""], do: nil, else: limit)
      end

      # The stored limit is the version's own planning input, read by the day load:
      # a blank saved last leaves no limit, and 720 then reaches the context as the
      # relief limit the checks compare stretches against.
      {:ok, blank} = Gtfs.load_blocking_day(organization.id, version.id, nil)
      assert blank.context.max_piece_minutes == nil

      assert {:ok, :ok} =
               Gtfs.update_relief_settings(organization.id, version.id, nil, %{
                 max_piece_minutes: 720,
                 marked: ["RIV"]
               })

      {:ok, day} = Gtfs.load_blocking_day(organization.id, version.id, nil)
      assert day.context.max_piece_minutes == 720
    end

    test "an unknown day type key, a staging version and a foreign version store nothing",
         context do
      %{organization: organization, version: version} = context

      planned_day(context)

      assert {:error, {:unknown_day_type, _day_types}} =
               Gtfs.update_relief_settings(organization.id, version.id, "SAT", %{
                 max_piece_minutes: 330,
                 marked: ["RIV"]
               })

      other_organization = organization_fixture()
      foreign_version = gtfs_version_fixture(other_organization.id)
      {:ok, staging} = Versions.create_staging_gtfs_version(organization.id, %{name: "Staging"})

      assert Gtfs.update_relief_settings(organization.id, foreign_version.id, nil, %{
               max_piece_minutes: 330,
               marked: ["RIV"]
             }) == {:error, :not_found}

      assert Gtfs.update_relief_settings(organization.id, staging.id, nil, %{
               max_piece_minutes: 330,
               marked: ["RIV"]
             }) == {:error, :not_found}

      # The version of the other organization is untouched too.
      assert Repo.aggregate(BlockingSetting, :count) == 0
      assert Repo.aggregate(ReliefPoint, :count) == 0
    end
  end

  describe "update_relief_settings/4 under a held blocking lock" do
    test "the writer waits for lock_blocking!/1 and succeeds after the release" do
      scope =
        unboxed(fn ->
          organization = organization_fixture()
          version = gtfs_version_fixture(organization.id)

          stop_with_coordinates_fixture(organization.id, version.id, %{
            stop_id: "VC",
            stop_name: "Valley College",
            stop_lat: Decimal.new("40.0100"),
            stop_lon: Decimal.new("-74.0")
          })

          stop_with_coordinates_fixture(organization.id, version.id, %{
            stop_id: "MS",
            stop_name: "Market Square",
            stop_lat: Decimal.new("40.0300"),
            stop_lon: Decimal.new("-74.0")
          })

          calendar_service_fixture(organization.id, version.id, %{
            service_id: "WK",
            name: "Weekday"
          })

          route = route_fixture(organization.id, version.id)

          for {trip_id, block_id, first, last, from, to} <- [
                {"a", "101", "09:00:00", "09:30:00", "VC", "VC"},
                {"b", "101", "10:30:00", "11:00:00", "MS", "MS"}
              ] do
            trip =
              trip_fixture(organization.id, version.id, route.route_id, %{
                trip_id: trip_id,
                service_id: "WK",
                block_id: block_id
              })

            stop_time_fixture(organization.id, version.id, trip_id, from, %{
              stop_sequence: 1,
              arrival_time: first,
              departure_time: first
            })

            stop_time_fixture(organization.id, version.id, trip_id, to, %{
              stop_sequence: 2,
              arrival_time: last,
              departure_time: last
            })

            trip
          end

          %{organization_id: organization.id, version_id: version.id}
        end)

      on_exit(fn -> cleanup_committed_scope(scope) end)

      parent = self()

      holder = Task.async(fn -> hold_blocking_lock(scope, parent) end)
      assert_receive :blocking_lock_held, @receive_timeout

      writer =
        Task.async(fn ->
          unboxed(fn ->
            {:ok, %{rows: [[backend_pid]]}} = Repo.query("select pg_backend_pid()")
            send(parent, {:writer_pid, backend_pid})

            Blocking.update_relief_settings(
              scope.organization_id,
              scope.version_id,
              nil,
              %{max_piece_minutes: 330, marked: ["MS"]}
            )
          end)
        end)

      assert_receive {:writer_pid, writer_pid}, @receive_timeout
      assert wait_until_locked(writer_pid)

      send(holder.pid, :release)
      Task.await(holder, @task_timeout)
      assert {:ok, :ok} = Task.await(writer, @task_timeout)

      # The save committed exactly the limit and the one mark, and the test's own
      # cleanup then removes the whole disposable scope.
      assert unboxed(fn ->
               Repo.aggregate(BlockingSetting, :count, organization_id: scope.organization_id)
             end) == 1

      assert unboxed(fn ->
               Repo.aggregate(ReliefPoint, :count, organization_id: scope.organization_id)
             end) == 1
    end
  end

  # The day the list cases read: 101 lays over inside Riverside Station once, 102
  # drives Valley College → Market Square with an hour of gap, and 103 lays over
  # inside the station again. 101 and 103 are the station's two waits; the drive is
  # one wait at each of its ends.
  defp planned_day(context) do
    trip!(context, "a", "101", "05:50:00", "06:50:00", "BAY_A", "BAY_A")
    trip!(context, "b", "101", "07:00:00", "08:00:00", "BAY_B", "BAY_B")
    trip!(context, "c", "102", "09:00:00", "09:30:00", "VC", "VC")
    trip!(context, "d", "102", "10:30:00", "11:00:00", "MS", "MS")
    trip!(context, "e", "103", "12:00:00", "12:30:00", "BAY_A", "BAY_A")
    trip!(context, "f", "103", "13:00:00", "13:30:00", "BAY_B", "BAY_B")
  end

  # One trip from `first_stop` at `first` to `last_stop` at `last`, so a case can
  # name the endpoints that make the handoff a layover or a move.
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

  defp candidate(candidates, stop_id) do
    Enum.find(candidates, &(&1.stop_id == stop_id))
  end

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

  # Deletes exactly the rows the lock case committed, keyed to their own
  # organization, on an own connection so the deletion is not part of the
  # sandboxed test transaction. The version's stop rows cascade, so the whole scope
  # goes with it.
  defp cleanup_committed_scope(scope) do
    unboxed(fn ->
      Repo.delete_all(
        from(s in GtfsPlanner.Gtfs.Stop, where: s.organization_id == ^scope.organization_id)
      )

      Repo.delete_all(from(v in GtfsVersion, where: v.organization_id == ^scope.organization_id))
      Repo.delete_all(from(o in Organization, where: o.id == ^scope.organization_id))
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

      attempts > 0 ->
        Process.sleep(20)
        wait_until_locked(pid, attempts - 1)

      true ->
        flunk("the writer never waited on the blocking lock")
    end
  end
end
