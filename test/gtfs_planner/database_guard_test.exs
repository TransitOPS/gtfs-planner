defmodule GtfsPlanner.DatabaseGuardTest do
  use ExUnit.Case, async: true

  alias GtfsPlanner.DatabaseGuard

  describe "ensure_droppable!/2" do
    test "allows a partitioned test database in the test environment" do
      assert :ok =
               DatabaseGuard.ensure_droppable!(:test, database: "gtfs_planner_exunit_partition")
    end

    test "allows the pg_tmp database named in the URL" do
      assert :ok =
               DatabaseGuard.ensure_droppable!(:test,
                 url: "postgresql://someone@127.0.0.1:54321/test"
               )
    end

    test "refuses the dev database in the dev environment" do
      assert_raise RuntimeError, ~r/Refusing to drop database "gtfs_planner_dev"/, fn ->
        DatabaseGuard.ensure_droppable!(:dev, database: "gtfs_planner_dev")
      end
    end

    test "refuses the dev database in the test environment" do
      assert_raise RuntimeError, ~r/Refusing to drop database "gtfs_planner_dev"/, fn ->
        DatabaseGuard.ensure_droppable!(:test, database: "gtfs_planner_dev")
      end
    end

    test "refuses a disposable name outside the test environment" do
      assert_raise RuntimeError, ~r/in the dev environment/, fn ->
        DatabaseGuard.ensure_droppable!(:dev, database: "gtfs_planner_exunit")
      end
    end

    test "refuses a database owned by the old test prefix" do
      assert_raise RuntimeError, ~r/"gtfs_planner_test_calendar17"/, fn ->
        DatabaseGuard.ensure_droppable!(:test, database: "gtfs_planner_test_calendar17")
      end
    end

    test "takes the database from the URL when both are set" do
      assert_raise RuntimeError, ~r/"gtfs_planner_dev"/, fn ->
        DatabaseGuard.ensure_droppable!(:test,
          database: "gtfs_planner_exunit",
          url: "ecto://postgres:postgres@localhost/gtfs_planner_dev"
        )
      end
    end

    test "refuses a config without a database" do
      assert_raise RuntimeError, ~r/Refusing to drop database nil/, fn ->
        DatabaseGuard.ensure_droppable!(:test, [])
      end
    end
  end
end
