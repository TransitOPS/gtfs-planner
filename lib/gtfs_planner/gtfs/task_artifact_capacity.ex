defmodule GtfsPlanner.Gtfs.TaskArtifactCapacity do
  @moduledoc false

  @spec within_limit(String.t(), non_neg_integer(), non_neg_integer() | :infinity, (-> term())) ::
          term()
  def within_limit(root, incoming_bytes, limit, fun)
      when is_binary(root) and is_integer(incoming_bytes) and incoming_bytes >= 0 and
             is_function(fun, 0) do
    lock_id = {{__MODULE__, Path.expand(root)}, self()}

    :global.trans(lock_id, fn ->
      if limit == :infinity or stored_bytes(root) + incoming_bytes <= limit,
        do: fun.(),
        else: {:error, :artifact_capacity_exceeded}
    end)
  end

  defp stored_bytes(root) do
    root
    |> Path.join("**/*")
    |> Path.wildcard()
    |> Enum.reduce(0, fn path, total ->
      case File.stat(path) do
        {:ok, %{type: :regular, size: size}} -> total + size
        _ -> total
      end
    end)
  end
end
