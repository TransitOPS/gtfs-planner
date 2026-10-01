defmodule GtfsPlanner.Release do
  @moduledoc """
  Used for executing DB release tasks when run in production without Mix
  installed.
  """

  alias GtfsPlanner.Integrity.OwnershipAudit

  @app :gtfs_planner

  def migrate do
    load_app()

    for repo <- repos() do
      {:ok, _, _} =
        Ecto.Migrator.with_repo(repo, fn repo ->
          Ecto.Migrator.run(repo, :up, all: true)
          backfill_legacy_diagrams!(repo)
        end)
    end

    :ok
  end

  def audit_ownership do
    load_app()

    reports =
      for repo <- repos() do
        {:ok, report, _} =
          Ecto.Migrator.with_repo(repo, fn repo ->
            OwnershipAudit.run(repo: repo)
          end)

        Enum.each(OwnershipAudit.report_lines(report), &IO.puts/1)
        report
      end

    total = Enum.sum(Enum.map(reports, & &1.total))
    if total == 0, do: :ok, else: {:error, total}
  end

  defp backfill_legacy_diagrams!(repo) do
    case GtfsPlanner.Gtfs.DiagramStorage.migrate_legacy_assets(repo) do
      {:ok, _count} ->
        :ok

      {:error, reason} ->
        raise "legacy diagram backfill failed: #{inspect(reason)}"
    end
  end

  def rollback(repo, version) do
    load_app()
    {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))
  end

  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end

  defp load_app do
    # Many platforms require SSL when connecting to the database
    Application.ensure_all_started(:ssl)
    Application.ensure_loaded(@app)
  end
end
