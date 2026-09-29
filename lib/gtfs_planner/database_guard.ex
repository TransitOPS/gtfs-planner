defmodule GtfsPlanner.DatabaseGuard do
  @moduledoc """
  Limits the `ecto.drop` Mix task to the disposable databases that tests create.

  The `ecto.drop` alias in `mix.exs` calls `ensure_droppable!/2` before the real task
  runs. The database names match the allowlist in `config/test.exs`.
  """

  @test_prefix "gtfs_planner_exunit"

  @doc """
  Raises unless `env` is `:test` and the Repo config names a database called `test`
  (the name `pg_tmp` gives its throwaway database) or one starting with
  `gtfs_planner_exunit`.

  `repo_config` is the Repo's application env. Like Ecto, it takes the database from
  `:url` when that is set and from `:database` otherwise.
  """
  @spec ensure_droppable!(atom(), keyword()) :: :ok
  def ensure_droppable!(env, repo_config) do
    database = database_name(repo_config)

    if env == :test and disposable?(database) do
      :ok
    else
      raise "Refusing to drop database #{inspect(database)} in the #{env} environment. " <>
              "Only the test environment may drop databases, and only `test` or " <>
              "names starting with `#{@test_prefix}`."
    end
  end

  defp database_name(repo_config) do
    case Keyword.get(repo_config, :url) do
      url when url in [nil, ""] ->
        Keyword.get(repo_config, :database)

      url ->
        %URI{path: path} = URI.parse(url)
        String.trim_leading(path || "", "/")
    end
  end

  defp disposable?(database) when is_binary(database) do
    database == "test" or String.starts_with?(database, @test_prefix)
  end

  defp disposable?(_database), do: false
end
