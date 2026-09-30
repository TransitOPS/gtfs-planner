defmodule GtfsPlanner.Gtfs.Runs.TripRunTest do
  @moduledoc """
  `trip_runs` holds at most one row per organization, version, day type and trip,
  the database refuses a malformed run ID, a deleted trip takes its assignments
  with it, and the five crew columns carry their researched defaults and their
  named ranges.

  The rejections are the property under test, so each case writes past the
  changeset where the changeset is not the thing being checked: a raw insert and a
  raw update name the constraint PostgreSQL raised, which is the guarantee a later
  writer cannot quietly remove by changing a changeset.

  Rows are created inside the SQL Sandbox transaction and rolled back. Each failing
  write runs in its own `Repo.transaction/1` so the violation rolls back to a
  savepoint instead of poisoning the case's transaction, as
  `blocking/settings_test.exs` does.

  Run with:
  `mix test test/gtfs_planner/gtfs/runs/trip_run_test.exs`.
  """
  use GtfsPlanner.DataCase, async: true

  alias GtfsPlanner.Gtfs.BlockingSetting
  alias GtfsPlanner.Gtfs.TripRun

  import GtfsPlanner.BlockingFixtures
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  @moduletag timeout: 120_000

  @crew_defaults %{
    report_pull_out_minutes: 15,
    report_relief_minutes: 5,
    sign_off_minutes: 5,
    paid_break_max_minutes: 30,
    max_spread_minutes: 720
  }

  setup do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    route = route_fixture(organization.id, version.id)

    trip =
      blocked_trip_fixture(organization.id, version.id, route.id, %{
        trip_id: "T1",
        block_id: "101"
      })

    %{organization: organization, version: version, trip: trip}
  end

  describe "one row per trip per day type" do
    test "a second row for the same organization, version, day type and trip is rejected",
         %{organization: organization, version: version, trip: trip} do
      insert_run(organization, version, trip, "WK", "R1")

      duplicate =
        scoped_run(organization, version, trip, "WK")
        |> TripRun.changeset(%{run_id: "R2"})

      assert {:error, duplicate} = Repo.insert(duplicate)
      # Ecto keys a multi-field unique constraint's error on the first field it
      # was given, so the duplicate names the scope rather than the trip.
      assert %{organization_id: ["has already been taken"]} = errors_on(duplicate)

      # The rule is about the day-type key, not the run: the same trip on the other
      # day type is a different assignment and stores.
      assert {:ok, _} =
               organization
               |> scoped_run(version, trip, "SA")
               |> TripRun.changeset(%{run_id: "R2"})
               |> Repo.insert()

      assert Repo.aggregate(from(t in TripRun, where: t.trip_id == ^trip.id), :count) == 2
    end

    test "a trip of another organization stores beside it", %{
      organization: organization,
      version: version,
      trip: trip
    } do
      insert_run(organization, version, trip, "WK", "R1")

      other_organization = organization_fixture()
      other_version = gtfs_version_fixture(other_organization.id)
      other_route = route_fixture(other_organization.id, other_version.id)

      other_trip =
        blocked_trip_fixture(other_organization.id, other_version.id, other_route.id, %{
          trip_id: "T1",
          block_id: "101"
        })

      assert {:ok, _} = insert_run(other_organization, other_version, other_trip, "WK", "R1")
      assert Repo.aggregate(TripRun, :count) == 2
    end
  end

  describe "run ID format" do
    test "the database refuses a nine-character ID and one with a space", %{
      organization: organization,
      version: version,
      trip: trip
    } do
      for run_id <- ["ABCDEFGHI", "1 2"] do
        assert_violation("run_id_format", fn ->
          Repo.transaction(fn ->
            Repo.insert_all(TripRun, [raw_run(organization, version, trip, "WK", run_id)])
          end)
        end)
      end

      assert Repo.aggregate(TripRun, :count) == 0
    end

    test "the changeset refuses the same two IDs by format", %{
      organization: organization,
      version: version,
      trip: trip
    } do
      for run_id <- ["ABCDEFGHI", "1 2"] do
        changeset =
          organization
          |> scoped_run(version, trip, "WK")
          |> TripRun.changeset(%{run_id: run_id})

        assert {:error, changeset} = Repo.insert(changeset)

        assert %{run_id: ["must be one to eight letters, digits or hyphens"]} =
                 errors_on(changeset)
      end

      assert Repo.aggregate(TripRun, :count) == 0
    end

    test "the scoping fields are not cast from submitted parameters", %{
      organization: organization,
      version: version,
      trip: trip
    } do
      changeset =
        organization
        |> scoped_run(version, trip, "WK")
        |> TripRun.changeset(%{
          run_id: "R1",
          organization_id: Ecto.UUID.generate(),
          gtfs_version_id: Ecto.UUID.generate(),
          trip_id: Ecto.UUID.generate(),
          day_type_key: "SA"
        })

      assert {:ok, stored} = Repo.insert(changeset)
      assert stored.organization_id == organization.id
      assert stored.gtfs_version_id == version.id
      assert stored.trip_id == trip.id
      assert stored.day_type_key == "WK"
    end
  end

  describe "deleting a trip" do
    test "takes its run assignments with it", %{
      organization: organization,
      version: version,
      trip: trip
    } do
      insert_run(organization, version, trip, "WK", "R1")
      insert_run(organization, version, trip, "SA", "R1")

      assert {:ok, _} = Repo.delete(trip)

      assert Repo.aggregate(TripRun, :count) == 0
    end
  end

  describe "crew columns" do
    test "a row written without them reads the researched defaults", %{
      organization: organization,
      version: version
    } do
      # Written with `insert_all/2`, which sends only the columns named here, so
      # the values read back are the migration's column defaults and not the
      # schema's own field defaults. The timestamps are named because
      # `timestamps/1` made them `NOT NULL`; the five crew columns are still the
      # ones this row does not carry.
      now = DateTime.utc_now()

      {1, nil} =
        Repo.insert_all(BlockingSetting, [
          %{
            id: Ecto.UUID.generate(),
            organization_id: organization.id,
            gtfs_version_id: version.id,
            inserted_at: now,
            updated_at: now
          }
        ])

      setting = settings(organization, version)

      assert Map.take(setting, Map.keys(@crew_defaults)) == @crew_defaults
    end

    test "the database refuses a value past each range by its named constraint", %{
      organization: organization,
      version: version
    } do
      insert_setting(organization, version)

      out_of_range = [
        {:report_pull_out_minutes, 31, "report_pull_out_range"},
        {:report_relief_minutes, 16, "report_relief_range"},
        {:sign_off_minutes, 16, "sign_off_range"},
        {:paid_break_max_minutes, 91, "paid_break_max_range"},
        {:max_spread_minutes, 1081, "max_spread_range"},
        {:max_spread_minutes, 239, "max_spread_range"}
      ]

      for {column, value, constraint} <- out_of_range do
        assert_violation(constraint, fn ->
          Repo.transaction(fn ->
            from(s in BlockingSetting, where: s.organization_id == ^organization.id)
            |> Repo.update_all(set: [{column, value}])
          end)
        end)
      end

      # Every rejection rolled back, so the row still holds the researched
      # defaults: a refused range does not partly write.
      assert Map.take(settings(organization, version), Map.keys(@crew_defaults)) == @crew_defaults
    end
  end

  # A struct with the scoping fields every writer owns, set from its arguments and
  # never from submitted parameters — the shape the `Runs` writers build.
  defp scoped_run(organization, version, trip, day_type_key) do
    %TripRun{
      organization_id: organization.id,
      gtfs_version_id: version.id,
      trip_id: trip.id,
      day_type_key: day_type_key
    }
  end

  defp insert_run(organization, version, trip, day_type_key, run_id) do
    organization
    |> scoped_run(version, trip, day_type_key)
    |> TripRun.changeset(%{run_id: run_id})
    |> Repo.insert()
  end

  defp raw_run(organization, version, trip, day_type_key, run_id) do
    now = DateTime.utc_now()

    %{
      id: Ecto.UUID.generate(),
      organization_id: organization.id,
      gtfs_version_id: version.id,
      trip_id: trip.id,
      day_type_key: day_type_key,
      run_id: run_id,
      # `timestamps/1` made these columns `NOT NULL`, and `insert_all/2` writes no
      # schema defaults, so the raw rows carry them by hand. Everything else about
      # the row stays the caller's: the run ID is the only thing varying.
      inserted_at: now,
      updated_at: now
    }
  end

  defp insert_setting(organization, version) do
    Repo.insert!(%BlockingSetting{
      organization_id: organization.id,
      gtfs_version_id: version.id
    })
  end

  defp settings(organization, version) do
    Repo.get_by!(BlockingSetting,
      organization_id: organization.id,
      gtfs_version_id: version.id
    )
  end

  # The constraint name is what proves the rejection came from the rule under
  # test. Ecto surfaces a raw write's violation as a driver error and a changeset
  # write's as `Ecto.ConstraintError`, so the assertion reads the message of
  # whatever is raised instead of pinning one exception type to a database detail.
  defp assert_violation(constraint, fun) do
    message =
      try do
        fun.()
        flunk("expected a violation naming #{constraint}, but the write succeeded")
      rescue
        error -> Exception.message(error)
      end

    assert message =~ constraint
  end
end
