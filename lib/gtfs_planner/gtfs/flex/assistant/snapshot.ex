defmodule GtfsPlanner.Gtfs.Flex.Assistant.Snapshot do
  @moduledoc """
  Boundary that establishes the read snapshot for one Flex policy workspace.

  Every part of one `GtfsPlanner.Gtfs.Flex.Assistant` workspace — the saved
  service, its areas and their geometry, the referenced calendar rows, the
  readiness facts and the computed checks — is read inside one PostgreSQL
  `REPEATABLE READ READ ONLY` transaction, so a controlled writer that commits
  between two of those reads cannot make the workspace describe two different
  database states (AC-1, AC-3).

  The production implementation sets that isolation on the transaction before its
  first source read. The SQL sandbox already holds an open transaction and
  cannot change its isolation, so a sandboxed test selects the no-op
  implementation; the interleaving test selects the production one.
  """

  @callback begin_read() :: :ok
end
