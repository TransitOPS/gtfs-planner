defmodule GtfsPlanner.Gtfs.Import.BatchProcessorTest do
  use GtfsPlanner.DataCase, async: true

  alias GtfsPlanner.Gtfs.Import.BatchProcessor
  alias GtfsPlanner.Gtfs.Level
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
    defp rows_to_events(rows) do
      rows
      |> Enum.with_index(1)
      |> Enum.map(fn {row, n} -> {:ok, n, row} end)
    end

    test "inserts all rows with small dataset and batch size", %{
      organization_id: org_id,
      gtfs_version_id: version_id,
      topic: topic
    } do
      # Create 10 rows with batch size of 3
      rows =
        for i <- 1..10 do
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
            rows_to_events(rows),
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
      rows =
        for i <- 1..10 do
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
          rows_to_events(rows),
          row_to_attrs_fn,
          organization_id: org_id,
          gtfs_version_id: version_id,
          file_name: "levels.txt",
          topic: topic,
          batch_size: 3
        )
      end)

      # Should receive 4 progress messages (one per batch)
      # With streaming, total is estimated per batch (processed + batch_size) since we don't know total upfront
      assert_receive {:import_progress, %{file: "levels.txt", processed: 3, total: _}}
      assert_receive {:import_progress, %{file: "levels.txt", processed: 6, total: _}}
      assert_receive {:import_progress, %{file: "levels.txt", processed: 9, total: _}}
      assert_receive {:import_progress, %{file: "levels.txt", processed: 10, total: _}}
    end

    test "returns error with physical source row when row conversion fails", %{
      organization_id: org_id,
      gtfs_version_id: version_id,
      topic: topic
    } do
      events = [
        {:ok, 2, %{"level_id" => "L1", "level_index" => "1.0"}},
        {:ok, 10, %{"level_id" => "L2", "level_index" => "2.0"}},
        {:ok, 27, %{"level_id" => "", "level_index" => "3.0"}},
        {:ok, 99, %{"level_id" => "L4", "level_index" => "4.0"}}
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
          events,
          row_to_attrs_fn,
          organization_id: org_id,
          gtfs_version_id: version_id,
          file_name: "levels.txt",
          topic: topic,
          batch_size: 3
        )

      assert {:error, %{file: "levels.txt", row: 27, reason: "missing required field: level_id"}} =
               result
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
      events = [{:ok, 1, %{"level_id" => "L1", "level_index" => "1.0"}}]

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
          events,
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
      events = [
        {:ok, 1, %{"level_id" => "L1", "level_index" => "1.0"}},
        {:ok, 2, %{"level_id" => "L2", "level_index" => "2.0"}},
        {:ok, 3, %{"level_id" => "L3", "level_index" => "3.0"}},
        {:ok, 4, %{"level_id" => "", "level_index" => "4.0"}}
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
                 events,
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
      assert levels == []
    end

    test "halts before inserting a structural error chunk and consumes no later events", %{
      organization_id: org_id,
      gtfs_version_id: version_id,
      topic: topic
    } do
      # Track which events are realized from the lazy source stream.
      events =
        [
          {:ok, 1, %{"level_id" => "L1", "level_index" => "1.0"}},
          {:ok, 2, %{"level_id" => "L2", "level_index" => "2.0"}},
          {:error,
           %GtfsPlanner.Gtfs.Import.ParseError{
             file: "levels.txt",
             row: 3,
             reason: :wrong_field_count
           }},
          {:ok, 4, %{"level_id" => "L4", "level_index" => "4.0"}}
        ]
        |> Stream.map(fn event ->
          Process.put(:bp_consumed, [event | Process.get(:bp_consumed, [])])
          event
        end)

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

      Process.put(:bp_consumed, [])

      result =
        BatchProcessor.insert_batched(
          Repo,
          Level,
          events,
          row_to_attrs_fn,
          organization_id: org_id,
          gtfs_version_id: version_id,
          file_name: "levels.txt",
          topic: topic,
          batch_size: 3
        )

      # The structural event rejects the chunk; no rows are inserted.
      assert {:error,
              %GtfsPlanner.Gtfs.Import.ParseError{
                file: "levels.txt",
                row: 3,
                reason: :wrong_field_count
              }} = result

      levels = Repo.all(Level)
      assert levels == []

      # Only the events before and including the structural error were realized;
      # the event after it (row 4) is never consumed.
      realized =
        Process.get(:bp_consumed, [])
        |> Enum.reverse()
        |> Enum.map(fn
          {:ok, n, _row} -> {:ok, n}
          {:error, %GtfsPlanner.Gtfs.Import.ParseError{row: n}} -> {:error, n}
        end)

      assert realized == [
               {:ok, 1},
               {:ok, 2},
               {:error, 3}
             ]
    end
  end

  describe "insert_batched_with_transactions/5" do
    test "commits complete batches, discards the error batch, and stops consuming", %{
      organization_id: org_id,
      gtfs_version_id: version_id,
      topic: topic
    } do
      events =
        [
          {:ok, 2, %{"level_id" => "L1", "level_index" => "1.0"}},
          {:ok, 3, %{"level_id" => "L2", "level_index" => "2.0"}},
          {:ok, 4, %{"level_id" => "L3", "level_index" => "3.0"}},
          {:error,
           %GtfsPlanner.Gtfs.Import.ParseError{
             file: "levels.txt",
             row: 5,
             reason: :wrong_field_count
           }},
          {:ok, 6, %{"level_id" => "L4", "level_index" => "4.0"}}
        ]
        |> Stream.map(fn event ->
          Process.put(:bp_transaction_consumed, [
            event | Process.get(:bp_transaction_consumed, [])
          ])

          event
        end)

      row_to_attrs_fn = fn row, organization_id, gtfs_version_id ->
        {level_index, _} = Float.parse(row["level_index"])

        {:ok,
         %{
           level_id: row["level_id"],
           level_index: level_index,
           organization_id: organization_id,
           gtfs_version_id: gtfs_version_id
         }}
      end

      Process.put(:bp_transaction_consumed, [])

      assert {:error, %GtfsPlanner.Gtfs.Import.ParseError{row: 5}} =
               BatchProcessor.insert_batched_with_transactions(
                 Repo,
                 Level,
                 events,
                 row_to_attrs_fn,
                 organization_id: org_id,
                 gtfs_version_id: version_id,
                 file_name: "levels.txt",
                 topic: topic,
                 batch_size: 2
               )

      assert Repo.all(Level) |> Enum.map(& &1.level_id) |> Enum.sort() == ["L1", "L2"]

      assert Process.get(:bp_transaction_consumed, [])
             |> Enum.reverse()
             |> Enum.map(fn
               {:ok, row, _} -> {:ok, row}
               {:error, %GtfsPlanner.Gtfs.Import.ParseError{row: row}} -> {:error, row}
             end) == [{:ok, 2}, {:ok, 3}, {:ok, 4}, {:error, 5}]
    end
  end
end
