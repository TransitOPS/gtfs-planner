defmodule GtfsPlanner.Gtfs.Runs.DeriveVersionTest do
  @moduledoc """
  Merge evidence (EV-18) for CL-6: every day type's runs come from the same
  derivation the page uses, so FH-9 stays rejected.

  FH-9 is two derivations drifting apart. The export derives a version's
  movements for every day type at once; the page derives one day type at a time.
  If those two answers a run type or a figure, a planner sees one thing on the
  summary and another in the exported file.

  The gate's independence field is **compared with `load_runs/3` per day type**,
  and that is the whole test: the same day, derived two ways, must give the same
  straight, split and share. A version-wide read and a single-day read agreeing
  is the property; either one on its own would prove nothing.

  The second half of the gate is that
  `test/gtfs_planner/gtfs/export/operations_movements_test.exs` passes
  **unchanged** — `export_movements/2` gained a key, and the export that consumes
  it must not have moved.

  Rows are created inside the SQL Sandbox transaction and rolled back.

  The focused gate command is deferred to branch review:
  `MIX_ENV=test MIX_TEST_PARTITION=_runs08 mix test test/gtfs_planner/gtfs/runs/derive_version_test.exs test/gtfs_planner/gtfs/export/operations_movements_test.exs`.
  """
  use GtfsPlanner.DataCase, async: true

  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.Blocking
  alias GtfsPlanner.Gtfs.Blocking.DayTypes
  alias GtfsPlanner.Gtfs.Runs

  import GtfsPlanner.BlockingFixtures
  import GtfsPlanner.RunsFixtures

  @moduletag timeout: 120_000

  setup do
    world = runs_version_fixture()

    # A second and third day type, so the version has three and the comparison
    # is across more than one.
    calendar_service_fixture(world.organization.id, world.version.id, %{
      service_id: "SAT",
      name: "Saturday",
      monday: 0,
      tuesday: 0,
      wednesday: 0,
      thursday: 0,
      friday: 0,
      saturday: 1,
      sunday: 0
    })

    calendar_service_fixture(world.organization.id, world.version.id, %{
      service_id: "SUN",
      name: "Sunday",
      monday: 0,
      tuesday: 0,
      wednesday: 0,
      thursday: 0,
      friday: 0,
      saturday: 0,
      sunday: 1
    })

    saturday = DayTypes.key(["SAT"])
    sunday = DayTypes.key(["SUN"])

    %{world: world, saturday_key: saturday, sunday_key: sunday}
  end

  defp shares(org_id, version_id) do
    {:ok, shares} = Gtfs.run_day_type_shares(org_id, version_id)
    Map.new(shares, &{&1.day_type_key, &1})
  end

  describe "day_type_shares/2" do
    test "every day type of the version is listed", %{
      world: world,
      saturday_key: saturday_key,
      sunday_key: sunday_key
    } do
      assert {:ok, listed} =
               Gtfs.run_day_type_shares(world.organization.id, world.version.id)

      keys = Enum.map(listed, & &1.day_type_key)

      assert Enum.sort(keys) ==
               Enum.sort([world.day_type_key, saturday_key, sunday_key])

      assert Enum.sort(Enum.map(listed, & &1.label)) == ["Saturday", "Sunday", "Weekday"]
    end

    test "a day type with no runs is listed with straight 0, split 0 and a nil share", %{
      world: world,
      saturday_key: saturday_key,
      sunday_key: sunday_key
    } do
      by_key = shares(world.organization.id, world.version.id)

      # The fixture day is unworked, so every day type is the empty case. A day
      # type omitted from the answer would look like a version without one.
      for key <- [world.day_type_key, saturday_key, sunday_key] do
        assert by_key[key].straight == 0
        assert by_key[key].split == 0
        assert by_key[key].share == nil
      end
    end

    test "a worked day type reports its straight, split and share", %{
      world: world,
      saturday_key: saturday_key,
      sunday_key: sunday_key
    } do
      # Block 101's four trips on one run, on the weekday day type.
      for trip <- world.blocks["101"] do
        trip_run_fixture(world.organization.id, world.version.id, %{
          trip: trip,
          day_type_key: world.day_type_key,
          run_id: "1001"
        })
      end

      by_key = shares(world.organization.id, world.version.id)

      {:ok, runs_day} =
        Gtfs.load_runs(world.organization.id, world.version.id, world.day_type_key)

      assert by_key[world.day_type_key].straight == runs_day.derived.stats.by_type.straight
      assert by_key[world.day_type_key].split == runs_day.derived.stats.by_type.split
      assert by_key[world.day_type_key].share == runs_day.derived.stats.straight_share

      # And the other two are still the empty case beside it.
      assert by_key[saturday_key].share == nil
      assert by_key[sunday_key].share == nil
    end

    test "an unpublished version is not found" do
      other = runs_version_fixture()

      {:ok, staging} =
        GtfsPlanner.Versions.create_staging_gtfs_version(other.organization.id, %{name: "Staging"})

      assert {:error, :not_found} = Gtfs.run_day_type_shares(other.organization.id, staging.id)
    end

    test "another organization's version is not found", %{world: world} do
      theirs = runs_version_fixture()

      assert {:error, :not_found} =
               Gtfs.run_day_type_shares(world.organization.id, theirs.version.id)
    end
  end

  describe "derive_version/3 against load_runs/3" do
    setup %{world: world, saturday_key: saturday_key} do
      # Work on two of the three day types, so the comparison covers a worked
      # and an unworked day rather than three of a kind.
      for trip <- world.blocks["101"] do
        trip_run_fixture(world.organization.id, world.version.id, %{
          trip: trip,
          day_type_key: world.day_type_key,
          run_id: "1001"
        })
      end

      saturday_trip =
        blocked_trip_fixture(world.organization.id, world.version.id, world.route.route_id, %{
          trip_id: "saturday_trip",
          service_id: "SAT",
          block_id: "101"
        })

      trip_run_fixture(world.organization.id, world.version.id, %{
        trip: saturday_trip,
        day_type_key: saturday_key,
        run_id: "2001"
      })

      :ok
    end

    test "straight, split and share equal load_runs/3's figures, per day type", %{
      world: world,
      saturday_key: saturday_key,
      sunday_key: sunday_key
    } do
      {:ok, listed} = Gtfs.run_day_type_shares(world.organization.id, world.version.id)
      by_key = Map.new(listed, &{&1.day_type_key, &1})

      for key <- [world.day_type_key, saturday_key, sunday_key] do
        {:ok, runs_day} = Gtfs.load_runs(world.organization.id, world.version.id, key)
        stats = runs_day.derived.stats

        assert by_key[key].straight == stats.by_type.straight,
               "straight disagrees for #{key}"

        assert by_key[key].split == stats.by_type.split, "split disagrees for #{key}"
        assert by_key[key].share == stats.straight_share, "share disagrees for #{key}"
      end
    end

    test "every run's own figures agree too, not only the day type's totals", %{world: world} do
      export = Blocking.export_movements(world.organization.id, world.version.id)

      assignments =
        Repo.all(
          from(row in GtfsPlanner.Gtfs.TripRun,
            where:
              row.organization_id == ^world.organization.id and
                row.gtfs_version_id == ^world.version.id,
            select: {row.day_type_key, row.trip_id, row.run_id}
          )
        )
        |> Enum.group_by(fn {key, _, _} -> key end, fn {_, trip, run} -> {trip, run} end)
        |> Map.new(fn {key, pairs} -> {key, Map.new(pairs)} end)

      # The real stored crew, not a hand-built one: `derive_version/3` is given
      # the same value `load_runs/3` reads, so the comparison is between the two
      # derivation paths and not between two different rule sets.
      crew = Runs.get_crew_settings(world.organization.id, world.version.id)
      derived = Runs.derive_version(export, assignments, crew)

      for {key, _} <- export.day_types do
        {:ok, runs_day} = Gtfs.load_runs(world.organization.id, world.version.id, key)

        # Run for run, not just in total: the same run must be the same type with
        # the same paid seconds whichever read produced it.
        assert Enum.map(derived[key].runs, &{&1.run_id, &1.work.type, &1.work.paid_secs}) ==
                 Enum.map(runs_day.derived.runs, &{&1.run_id, &1.work.type, &1.work.paid_secs})
      end
    end

    test "derive_version answers a key for every day type the export listed", %{world: world} do
      export = Blocking.export_movements(world.organization.id, world.version.id)
      crew = Runs.get_crew_settings(world.organization.id, world.version.id)
      derived = Runs.derive_version(export, %{}, crew)

      assert Enum.sort(Map.keys(derived)) == Enum.sort(Enum.map(export.day_types, & &1.key))
    end
  end

  describe "export_movements/2" do
    test "returns a context per day type, keyed by the day type's own key", %{world: world} do
      export = Blocking.export_movements(world.organization.id, world.version.id)

      assert Enum.sort(Map.keys(export.contexts_by_day_type)) ==
               Enum.sort(Enum.map(export.day_types, & &1.key))

      for {_key, context} <- export.contexts_by_day_type do
        assert %Blocking.Context{} = context
        assert is_integer(context.min_layover_minutes)
        assert MapSet.size(context.relief_stop_ids) > 0
      end
    end

    test "the returned context is the one the day load builds for that day type", %{world: world} do
      export = Blocking.export_movements(world.organization.id, world.version.id)

      for day_type <- export.day_types do
        {:ok, runs_day} = Gtfs.load_runs(world.organization.id, world.version.id, day_type.key)

        # Same inputs, so the two derivations of this version's day types agree
        # because they were given the same value rather than because two
        # implementations were compared afterwards.
        assert export.contexts_by_day_type[day_type.key] == runs_day.day.context
      end
    end
  end
end
