defmodule GtfsPlanner.Gtfs.Export.Snapshot do
  @moduledoc """
  Boundary that establishes the read snapshot for a GTFS export.

  All GTFS files of one export are read from a single repeatable-read snapshot so
  a concurrent committed edit is either entirely visible or entirely invisible.
  The production implementation sets that isolation on the export transaction
  before its first query. Tests that run inside the SQL sandbox already hold an
  open transaction and cannot change its isolation, so they select a no-op
  implementation; the export-race test selects the production one.
  """

  @callback begin_read() :: :ok
end
