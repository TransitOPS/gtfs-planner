defmodule GtfsPlanner.Agents.UsageBudgetTest do
  use GtfsPlanner.DataCase, async: false

  import GtfsPlanner.ConcurrencyHelpers, only: [unboxed: 1]

  alias GtfsPlanner.Agents.UsageBudget
  alias GtfsPlanner.Agents.UsageCounter
  alias GtfsPlanner.Organizations.Organization

  setup do
    previous = Application.fetch_env!(:gtfs_planner, UsageBudget)

    Application.put_env(:gtfs_planner, UsageBudget,
      organization_daily_attempts: 10,
      actor_daily_attempts: 3
    )

    on_exit(fn -> Application.put_env(:gtfs_planner, UsageBudget, previous) end)

    organization =
      unboxed(fn ->
        Repo.insert!(%Organization{
          alias: "budget-#{System.unique_integer([:positive])}",
          name: "Usage budget test"
        })
      end)

    on_exit(fn -> unboxed(fn -> Repo.delete!(organization) end) end)

    %{organization: organization}
  end

  test "the fourth actor attempt is refused after three committed charges", %{organization: org} do
    actor_id = Ecto.UUID.generate()

    unboxed(fn ->
      assert Enum.map(1..3, fn _ -> UsageBudget.consume(org.id, actor_id) end) ==
               [:ok, :ok, :ok]

      assert {:error, :allowance_exhausted} = UsageBudget.consume(org.id, actor_id)
      assert attempts(org.id, "organization") == 3
      assert attempts(org.id, actor_id) == 3
    end)
  end

  test "the organization limit applies across actors", %{organization: org} do
    Application.put_env(:gtfs_planner, UsageBudget,
      organization_daily_attempts: 3,
      actor_daily_attempts: 3
    )

    first_actor = Ecto.UUID.generate()
    second_actor = Ecto.UUID.generate()

    unboxed(fn ->
      assert :ok = UsageBudget.consume(org.id, first_actor)
      assert :ok = UsageBudget.consume(org.id, first_actor)
      assert :ok = UsageBudget.consume(org.id, second_actor)
      assert {:error, :allowance_exhausted} = UsageBudget.consume(org.id, second_actor)

      assert attempts(org.id, "organization") == 3
      assert attempts(org.id, first_actor) == 2
      assert attempts(org.id, second_actor) == 1
    end)
  end

  test "yesterday's count does not consume today's allowance", %{organization: org} do
    actor_id = Ecto.UUID.generate()

    unboxed(fn ->
      %{rows: [[today]]} = Repo.query!("SELECT (now() AT TIME ZONE 'UTC')::date")

      Repo.insert!(%UsageCounter{
        organization_id: org.id,
        scope_key: actor_id,
        day: Date.add(today, -1),
        attempts: 3
      })

      assert :ok = UsageBudget.consume(org.id, actor_id)
      assert attempts(org.id, actor_id) == 1
      assert attempts(org.id, "organization") == 1
    end)
  end

  defp attempts(organization_id, scope_key) do
    %{rows: [[today]]} = Repo.query!("SELECT (now() AT TIME ZONE 'UTC')::date")

    Repo.one(
      from c in UsageCounter,
        where:
          c.organization_id == ^organization_id and c.scope_key == ^scope_key and
            c.day == ^today,
        select: c.attempts
    )
  end
end
