defmodule GtfsPlanner.Gtfs.Import.BatchProcessorTest do
  use GtfsPlanner.DataCase, async: true

  alias GtfsPlanner.Gtfs.Import.BatchProcessor
  alias GtfsPlanner.Gtfs.{Level, Stop}
  alias GtfsPlanner.Repo

  setup do
    organization = GtfsPlanner.OrganizationsFixtures.organization_fixture()
    gtfs_version = GtfsPlanner.VersionsFixtures.gtfs_version_fixture(organization.id)

    # Subscribe to a test topic for progress messages
    topic = "test_import_#{:erlang.unique_integer()}"
    Phoenix.PubSub.subscribe(GtfsPlanner.PubSub, topic)

    %{
      organization_id: organization.id,
      gtfs_version_id: gtfs_version.id,
      topic: topic
    }
  end

  describe "insert_batched/5" do
    test "inserts all rows with small dataset and batch size", %{
      organization_id: org_id,
      gtfs_version_id: version_id,
      topic: topic
    } do
      # Create 10 rows with batch size of 3
      rows = for i <- 1..10 do
        %{
          "level_id" => "L#{i}",
          "level_index" => "#{i}.0",
          "level_name" => "Level #{i}"
        }
      end

      row_to_attrs_fn = fn row, org_id, version_id ->
        {level_index, _} = Float.parse(row["level_index"])

        {:ok,
         %{
           level_id: row["level_id"],
           level_index: level_index,
           level_name: row["level_name"],
           organization_id: org_id,
           gtfs_version_id: version_id
         }}
      end

      # Wrap in transaction to test atomicity
      result =
        Repo.transaction(fn ->
          BatchProcessor.insert_batched(
            Repo,
            Level,
            rows,
            row_to_attrs_fn,
            organization_id: org_id,
            gtfs_version_id: version_id,
            file_name: "levels.txt",
            topic: topic,
            batch_size: 3
          )
        end)

      assert {:ok, {:ok, 10}} = result

      # Verify all levels were inserted
      levels = Repo.all(Level)
      assert length(levels) == 10
    end

    test "broadcasts progress correct number of times", %{
      organization_id: org_id,
      gtfs_version_id: version_id,
      topic: topic
    } do
      # 10 rows with batch size 3 = 4 batches (3+3+3+1)
      rows = for i <- 1..10 do
        %{
          "level_id" => "L#{i}",
          "level_index" => "#{i}.0"
        }
      end

      row_to_attrs_fn = fn row, org_id, version_id ->
        {level_index, _} = Float.parse(row["level_index"])

        {:ok,
         %{
           level_id: row["level_id"],
           level_index: level_index,
           organization_id: org_id,
           gtfs_version_id: version_id
         }}
      end

      Repo.transaction(fn ->
        BatchProcessor.insert_batched(
          Repo,
          Level,
          rows,
          row_to_attrs_fn,
          organization_id: org_id,
          gtfs_version_id: version_id,
          file_name: "levels.txt",
          topic: topic,
          batch_size: 3
        )
      end)

      # Should receive 4 progress messages (one per batch)
      assert_receive {:import_progress, %{file: "levels.txt", processed: 3, total: 10}}
      assert_receive {:import_progress, %{file: "levels.txt", processed: 6, total: 10}}
      assert_receive {:import_progress, %{file: "levels.txt", processed: 9, total: 10}}
      assert_receive {:import_progress, %{file: "levels.txt", processed: 10, total: 10}}
    end

    test "returns error when row conversion fails", %{
      organization_id: org_id,
      gtfs_version_id: version_id,
      topic: topic
    } do
      rows = [
        %{"level_id" => "L1", "level_index" => "1.0"},
        %{"level_id" => "L2", "level_index" => "2.0"},
        %{"level_id" => "", "level_index" => "3.0"},
        %{"level_id" => "L4", "level_index" => "4.0"}
      ]

      row_to_attrs_fn = fn row, org_id, version_id ->
        if row["level_id"] == "" do
          {:error, "missing required field: level_id"}
        else
          {level_index, _} = Float.parse(row["level_index"])

          {:ok,
           %{
             level_id: row["level_id"],
             level_index: level_index,
             organization_id: org_id,
             gtfs_version_id: version_id
           }}
        end
      end

      result =
        BatchProcessor.insert_batched(
          Repo,
          Level,
          rows,
          row_to_attrs_fn,
          organization_id: org_id,
          gtfs_version_id: version_id,
          file_name: "levels.txt",
          topic: topic,
          batch_size: 3
        )

      assert {:error, %{file: "levels.txt", row: 3, reason: "missing required field: level_id"}} = result
    end

    test "returns error when database constraint is violated", %{
      organization_id: org_id,
      gtfs_version_id: version_id,
      topic: topic
    } do
      # First, create a level directly
      {:ok, _} =
        Repo.insert(%Level{
          level_id: "L1",
          level_index: 0.0,
          organization_id: org_id,
          gtfs_version_id: version_id
        })

      # Now try to insert duplicate level_id via batch processor
      rows = [
        %{"level_id" => "L1", "level_index" => "1.0"}
      ]

      row_to_attrs_fn = fn row, org_id, version_id ->
        {level_index, _} = Float.parse(row["level_index"])

        {:ok,
         %{
           level_id: row["level_id"],
           level_index: level_index,
           organization_id: org_id,
           gtfs_version_id: version_id
         }}
      end

      result =
        BatchProcessor.insert_batched(
          Repo,
          Level,
          rows,
          row_to_attrs_fn,
          organization_id: org_id,
          gtfs_version_id: version_id,
          file_name: "levels.txt",
          topic: topic
        )

      assert {:error, %{file: "levels.txt", constraint: _}} = result
    end

    test "transaction rollback on batch failure", %{
      organization_id: org_id,
      gtfs_version_id: version_id,
      topic: topic
    } do
      # First batch succeeds, second batch fails
      rows = [
        %{"level_id" => "L1", "level_index" => "1.0"},
        %{"level_id" => "L2", "level_index" => "2.0"},
        %{"level_id" => "L3", "level_index" => "3.0"},
        %{"level_id" => "", "level_index" => "4.0"}
      ]

      row_to_attrs_fn = fn row, org_id, version_id ->
        if row["level_id"] == "" do
          {:error, "missing level_id"}
        else
          {level_index, _} = Float.parse(row["level_index"])

          {:ok,
           %{
             level_id: row["level_id"],
             level_index: level_index,
             organization_id: org_id,
             gtfs_version_id: version_id
           }}
        end
      end

      # Wrap in transaction - should rollback on error
      result =
        Repo.transaction(fn ->
          case BatchProcessor.insert_batched(
                 Repo,
                 Level,
                 rows,
                 row_to_attrs_fn,
                 organization_id: org_id,
                 gtfs_version_id: version_id,
                 file_name: "levels.txt",
                 topic: topic,
                 batch_size: 2
               ) do
            {:ok, count} -> count
            {:error, reason} -> Repo.rollback(reason)
          end
        end)

      assert {:error, _} = result

      # Verify no levels were inserted (transaction rolled back)
      levels = Repo.all(Level)
      assert length(levels) == 0
    end
  end

  describe "build_stop_lookup_map/3" do
    test "builds map of stop_id to UUID", %{
      organization_id: org_id,
      gtfs_version_id: version_id
    } do
      # Create some stops
      {:ok, stop1} =
        Repo.insert(%Stop{
          stop_id: "S1",
          stop_name: "Stop 1",
          stop_lat: Decimal.new("40.7"),
          stop_lon: Decimal.new("-74.0"),
          organization_id: org_id,
          gtfs_version_id: version_id
        })

      {:ok, stop2} =
        Repo.insert(%Stop{
          stop_id: "S2",
          stop_name: "Stop 2",
          stop_lat: Decimal.new("40.8"),
          stop_lon: Decimal.new("-74.1"),
          organization_id: org_id,
          gtfs_version_id: version_id
        })

      # Build lookup map
      stop_map = BatchProcessor.build_stop_lookup_map(Repo, org_id, version_id)

      assert map_size(stop_map) == 2
      assert stop_map["S1"] == stop1.id
      assert stop_map["S2"] == stop2.id
    end

    test "returns empty map when no stops exist", %{
      organization_id: org_id,
      gtfs_version_id: version_id
    } do
      stop_map = BatchProcessor.build_stop_lookup_map(Repo, org_id, version_id)
      assert stop_map == %{}
    end

    test "only includes stops for specified organization and version", %{
      organization_id: org_id,
      gtfs_version_id: version_id
    } do
      # Create stop for this org/version
      {:ok, stop1} =
        Repo.insert(%Stop{
          stop_id: "S1",
          stop_name: "Stop 1",
          stop_lat: Decimal.new("40.7"),
          stop_lon: Decimal.new("-74.0"),
          organization_id: org_id,
          gtfs_version_id: version_id
        })

      # Create stop for different org
      other_org = GtfsPlanner.OrganizationsFixtures.organization_fixture()
      other_version = GtfsPlanner.VersionsFixtures.gtfs_version_fixture(other_org.id)

      {:ok, _stop2} =
        Repo.insert(%Stop{
          stop_id: "S2",
          stop_name: "Stop 2",
          stop_lat: Decimal.new("40.8"),
          stop_lon: Decimal.new("-74.1"),
          organization_id: other_org.id,
          gtfs_version_id: other_version.id
        })

      # Build lookup map
      stop_map = BatchProcessor.build_stop_lookup_map(Repo, org_id, version_id)

      assert map_size(stop_map) == 1
      assert stop_map["S1"] == stop1.id
      refute Map.has_key?(stop_map, "S2")
    end
  end
end