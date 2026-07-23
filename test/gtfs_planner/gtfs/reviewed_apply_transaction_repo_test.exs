defmodule GtfsPlanner.Gtfs.ReviewedApplyTransaction.RepoTest do
  use GtfsPlanner.DataCase, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias GtfsPlanner.Gtfs.ReviewedApplyTransaction
  alias GtfsPlanner.Repo

  test "runs the production transaction at serializable isolation" do
    Sandbox.unboxed_run(Repo, fn ->
      assert {:ok, "serializable"} =
               ReviewedApplyTransaction.Repo.run(fn ->
                 %Postgrex.Result{rows: [[isolation]]} =
                   Repo.query!("SHOW transaction_isolation")

                 isolation
               end)
    end)
  end
end
