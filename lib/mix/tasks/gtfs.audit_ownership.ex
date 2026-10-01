defmodule Mix.Tasks.Gtfs.AuditOwnership do
  @moduledoc """
  Report GTFS ownership anomalies without changing the database.

      mix gtfs.audit_ownership

  Before running the ownership validation migration on a release target, run:

      bin/gtfs_planner eval 'case GtfsPlanner.Release.audit_ownership() do :ok -> :ok; {:error, _count} -> System.halt(1) end'

  Proceed with that migration only when the audit exits successfully. Anomalies
  require investigation and a separate, authorized resolution; this task never
  repairs rows.
  """

  use Mix.Task

  alias GtfsPlanner.Integrity.OwnershipAudit

  @shortdoc "Report GTFS ownership anomalies"

  @impl Mix.Task
  def run([]) do
    Mix.Task.run("app.start")

    report = OwnershipAudit.run()
    Enum.each(OwnershipAudit.report_lines(report), &IO.puts/1)

    if report.total > 0, do: exit({:shutdown, 1})
    :ok
  end
end
