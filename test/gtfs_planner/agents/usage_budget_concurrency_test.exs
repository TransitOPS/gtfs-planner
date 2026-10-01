defmodule GtfsPlanner.Agents.UsageBudgetConcurrencyTest do
  use GtfsPlanner.DataCase, async: false

  import GtfsPlanner.ConcurrencyHelpers, only: [unboxed: 1]

  alias GtfsPlanner.Agents.UsageBudget
  alias GtfsPlanner.Agents.UsageCounter
  alias GtfsPlanner.Organizations.Organization

  test "ten independent database sessions admit exactly three actor charges" do
    previous = Application.fetch_env!(:gtfs_planner, UsageBudget)

    Application.put_env(:gtfs_planner, UsageBudget,
      organization_daily_attempts: 10,
      actor_daily_attempts: 3
    )

    on_exit(fn -> Application.put_env(:gtfs_planner, UsageBudget, previous) end)

    organization =
      unboxed(fn ->
        Repo.insert!(%Organization{
          alias: "budget-race-#{System.unique_integer([:positive])}",
          name: "Usage budget race"
        })
      end)

    on_exit(fn -> unboxed(fn -> Repo.delete!(organization) end) end)
    actor_id = Ecto.UUID.generate()

    results =
      1..10
      |> Task.async_stream(
        fn _ -> unboxed(fn -> UsageBudget.consume(organization.id, actor_id) end) end,
        max_concurrency: 10,
        timeout: 15_000
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.count(results, &(&1 == :ok)) == 3
    assert Enum.count(results, &(&1 == {:error, :allowance_exhausted})) == 7

    unboxed(fn ->
      assert Repo.aggregate(
               from(c in UsageCounter,
                 where: c.organization_id == ^organization.id and c.scope_key == ^actor_id
               ),
               :max,
               :attempts
             ) == 3

      assert Repo.aggregate(
               from(c in UsageCounter,
                 where: c.organization_id == ^organization.id and c.scope_key == "organization"
               ),
               :max,
               :attempts
             ) == 3
    end)
  end
end
