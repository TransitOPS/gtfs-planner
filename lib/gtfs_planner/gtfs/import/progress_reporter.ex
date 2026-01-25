defmodule GtfsPlanner.Gtfs.Import.ProgressReporter do
  @moduledoc """
  Handles progress reporting for GTFS imports via Phoenix.PubSub.

  Broadcasts import progress events to subscribers, enabling real-time
  UI updates during long-running import operations.
  """

  @doc """
  Broadcasts progress for an ongoing import operation.

  ## Parameters

    * `topic` - The PubSub topic to broadcast to
    * `file_name` - Name of the file being processed
    * `processed_count` - Number of rows processed so far
    * `total_count` - Total number of rows to process

  ## Examples

      iex> broadcast_progress("import:123", "stops.txt", 1000, 5000)
      :ok
  """
  def broadcast_progress(topic, file_name, processed_count, total_count) do
    Phoenix.PubSub.broadcast(
      GtfsPlanner.PubSub,
      topic,
      {:import_progress,
       %{
         file: file_name,
         processed: processed_count,
         total: total_count
       }}
    )
  end

  @doc """
  Broadcasts a completion event for a successful import.

  ## Parameters

    * `topic` - The PubSub topic to broadcast to
    * `counts` - Map of imported record counts by type

  ## Examples

      iex> broadcast_complete("import:123", %{stops: 100, routes: 10})
      :ok
  """
  def broadcast_complete(topic, counts) do
    Phoenix.PubSub.broadcast(
      GtfsPlanner.PubSub,
      topic,
      {:import_complete, counts}
    )
  end

  @doc """
  Broadcasts an error event during import.

  ## Parameters

    * `topic` - The PubSub topic to broadcast to
    * `file_name` - Name of the file where error occurred
    * `error` - Error details or message

  ## Examples

      iex> broadcast_error("import:123", "stops.txt", "Invalid format")
      :ok
  """
  def broadcast_error(topic, file_name, error) do
    Phoenix.PubSub.broadcast(
      GtfsPlanner.PubSub,
      topic,
      {:import_error, %{file: file_name, error: error}}
    )
  end
end
