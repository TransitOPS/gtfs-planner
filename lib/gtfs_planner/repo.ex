defmodule GtfsPlanner.Repo do
  use Ecto.Repo,
    otp_app: :gtfs_planner,
    adapter: Ecto.Adapters.Postgres

  @retryable_conflict_codes [:serialization_failure, "40001", :deadlock_detected, "40P01"]

  @doc """
  Returns true when a database error is a PostgreSQL serialization failure or deadlock.

  Matches the code as either the Postgrex atom or the raw string form and returns false
  for every other term, so write retry loops share one conflict classifier.
  """
  @spec retryable_conflict?(term()) :: boolean()
  def retryable_conflict?(%Postgrex.Error{postgres: %{code: code}})
      when code in @retryable_conflict_codes,
      do: true

  def retryable_conflict?(_reason), do: false
end
