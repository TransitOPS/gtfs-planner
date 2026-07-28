defmodule GtfsPlanner.Reachability.Scoring do
  @moduledoc """
  Pure outcome policy for reachability pair and run results.
  """

  alias GtfsPlanner.Routing.Route

  @type pair_outcome :: :reachable | :unreachable | :invalid
  @type run_outcome :: :passed | :warning | :failed | :not_applicable

  @spec pair_outcome({:ok, Route.t()} | {:error, term()}) :: pair_outcome()
  def pair_outcome({:ok, _route}), do: :reachable
  def pair_outcome({:error, :no_path}), do: :unreachable
  def pair_outcome({:error, {:unknown_element, _}}), do: :invalid
  def pair_outcome({:error, :same_origin_and_destination}), do: :invalid

  @spec run_outcome([%{mode: atom(), outcome: pair_outcome()}]) :: run_outcome()
  def run_outcome([]), do: :not_applicable

  def run_outcome(results) do
    cond do
      Enum.any?(results, &(&1.outcome == :invalid)) -> :failed
      Enum.any?(results, &(&1.mode == :walking and &1.outcome == :unreachable)) -> :failed
      Enum.any?(results, &(&1.mode == :wheelchair and &1.outcome == :unreachable)) -> :warning
      true -> :passed
    end
  end

  @spec counts([%{mode: atom(), outcome: pair_outcome()}]) :: %{
          errors: non_neg_integer(),
          warnings: non_neg_integer(),
          infos: non_neg_integer()
        }
  def counts(results) do
    errors =
      Enum.count(results, fn r ->
        (r.mode == :walking and r.outcome == :unreachable) or r.outcome == :invalid
      end)

    warnings =
      Enum.count(results, fn r ->
        r.mode == :wheelchair and r.outcome == :unreachable
      end)

    infos = Enum.count(results, &(&1.outcome == :reachable))

    %{errors: errors, warnings: warnings, infos: infos}
  end
end
