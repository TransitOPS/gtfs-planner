defmodule GtfsPlanner.Agents.UsageBudget do
  @moduledoc "Charges an organization's and actor's daily provider-attempt allowances."

  alias GtfsPlanner.Repo

  @upsert """
  INSERT INTO agent_usage_counters (
    id, organization_id, scope_key, day, attempts, inserted_at, updated_at
  ) VALUES ($1, $2, $3, (now() AT TIME ZONE 'UTC')::date, 1, now(), now())
  ON CONFLICT (organization_id, scope_key, day)
  DO UPDATE SET attempts = agent_usage_counters.attempts + 1, updated_at = now()
  WHERE agent_usage_counters.attempts < $4
  RETURNING attempts
  """

  @spec consume(Ecto.UUID.t(), Ecto.UUID.t()) :: :ok | {:error, :allowance_exhausted}
  def consume(organization_id, actor_id) do
    limits = Application.fetch_env!(:gtfs_planner, __MODULE__)
    organization_id = Ecto.UUID.dump!(organization_id)

    case Repo.transaction(fn ->
           charge!(
             organization_id,
             "organization",
             Keyword.fetch!(limits, :organization_daily_attempts)
           )

           charge!(organization_id, actor_id, Keyword.fetch!(limits, :actor_daily_attempts))
         end) do
      {:ok, :ok} -> :ok
      {:error, :allowance_exhausted} -> {:error, :allowance_exhausted}
    end
  end

  defp charge!(organization_id, scope_key, limit) do
    case Repo.query!(@upsert, [
           Ecto.UUID.dump!(Ecto.UUID.generate()),
           organization_id,
           scope_key,
           limit
         ]) do
      %{rows: [[_attempts]]} -> :ok
      %{rows: []} -> Repo.rollback(:allowance_exhausted)
    end
  end
end
