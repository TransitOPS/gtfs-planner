defmodule GtfsPlanner.Gtfs.Import.ProgressReporterTest do
  use ExUnit.Case, async: true

  alias GtfsPlanner.Gtfs.Import.ProgressReporter

  setup do
    # Generate unique topic for each test to avoid cross-test interference
    topic = "test_import:#{:erlang.unique_integer()}"

    # Subscribe to the test topic to receive broadcasts
    Phoenix.PubSub.subscribe(GtfsPlanner.PubSub, topic)

    {:ok, topic: topic}
  end

  describe "broadcast_progress/4" do
    test "broadcasts progress message with correct format", %{topic: topic} do
      file_name = "stops.txt"
      processed_count = 1000
      total_count = 5000

      # Broadcast progress
      assert :ok =
               ProgressReporter.broadcast_progress(topic, file_name, processed_count, total_count)

      # Assert we receive the correct message
      assert_receive {:import_progress, progress_data}

      assert progress_data.file == file_name
      assert progress_data.processed == processed_count
      assert progress_data.total == total_count
    end

    test "broadcasts multiple progress updates", %{topic: topic} do
      # Broadcast first update
      ProgressReporter.broadcast_progress(topic, "routes.txt", 500, 1000)

      # Broadcast second update
      ProgressReporter.broadcast_progress(topic, "routes.txt", 1000, 1000)

      # Should receive both messages
      assert_receive {:import_progress, %{processed: 500}}
      assert_receive {:import_progress, %{processed: 1000}}
    end

    test "broadcasts to different files independently", %{topic: topic} do
      ProgressReporter.broadcast_progress(topic, "stops.txt", 100, 200)
      ProgressReporter.broadcast_progress(topic, "routes.txt", 50, 100)

      # Should receive messages for both files
      assert_receive {:import_progress, %{file: "stops.txt", processed: 100}}
      assert_receive {:import_progress, %{file: "routes.txt", processed: 50}}
    end
  end

  describe "broadcast_complete/2" do
    test "broadcasts completion message with counts", %{topic: topic} do
      counts = %{
        routes: 10,
        stops: 100,
        pathways: 50
      }

      assert :ok = ProgressReporter.broadcast_complete(topic, counts)

      # Assert we receive the correct message
      assert_receive {:import_complete, received_counts}

      assert received_counts == counts
      assert received_counts.routes == 10
      assert received_counts.stops == 100
      assert received_counts.pathways == 50
    end

    test "broadcasts completion with empty counts", %{topic: topic} do
      counts = %{}

      ProgressReporter.broadcast_complete(topic, counts)

      assert_receive {:import_complete, %{}}
    end
  end

  describe "broadcast_error/3" do
    test "broadcasts error message with file and error details", %{topic: topic} do
      file_name = "stops.txt"
      error = "Invalid format on line 42"

      assert :ok = ProgressReporter.broadcast_error(topic, file_name, error)

      # Assert we receive the correct message
      assert_receive {:import_error, error_data}

      assert error_data.file == file_name
      assert error_data.error == error
    end

    test "broadcasts error with map error details", %{topic: topic} do
      file_name = "pathways.txt"
      error = %{constraint: "foreign_key", message: "Stop not found"}

      ProgressReporter.broadcast_error(topic, file_name, error)

      assert_receive {:import_error, error_data}

      assert error_data.file == file_name
      assert error_data.error == error
    end
  end

  describe "message format validation" do
    test "progress message has all required keys", %{topic: topic} do
      ProgressReporter.broadcast_progress(topic, "test.txt", 10, 20)

      assert_receive {:import_progress, data}

      # Verify all required keys are present
      assert Map.has_key?(data, :file)
      assert Map.has_key?(data, :processed)
      assert Map.has_key?(data, :total)

      # Verify keys have correct types
      assert is_binary(data.file)
      assert is_integer(data.processed)
      assert is_integer(data.total)
    end

    test "error message has all required keys", %{topic: topic} do
      ProgressReporter.broadcast_error(topic, "test.txt", "error")

      assert_receive {:import_error, data}

      # Verify all required keys are present
      assert Map.has_key?(data, :file)
      assert Map.has_key?(data, :error)
    end
  end
end
