defmodule GtfsPlanner.TestSupport.ControlledReachabilityRunner do
  @moduledoc false

  alias GtfsPlanner.Reachability.Runner

  @owner_key {__MODULE__, :owner}

  def put_owner(pid), do: :persistent_term.put(@owner_key, pid)
  def clear_owner, do: :persistent_term.erase(@owner_key)

  def run(snapshot, started_at) do
    owner = :persistent_term.get(@owner_key)
    send(owner, {:controlled_runner_started, self()})

    receive do
      :complete -> Runner.run(snapshot, started_at)
      :fail -> {:error, :injected_failure}
    end
  end
end
