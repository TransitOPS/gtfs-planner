defmodule GtfsPlanner.Gtfs.ServiceQueries.Snapshot do
  @moduledoc """
  Boundary that establishes the read snapshot for one service query.

  Every part of one `GtfsPlanner.Gtfs.ServiceQueries` answer - rows, totals,
  exclusions and the content digest - is read inside one PostgreSQL
  `REPEATABLE READ READ ONLY` transaction, so a controlled writer that commits
  between two reads cannot make the parts describe different database states
  (AC-12). The production implementation sets that isolation before the query's
  first source read. The SQL sandbox already holds an open transaction and
  cannot change its isolation, so a test selects the no-op implementation; the
  interleaving case selects the production one.
  """

  @callback begin_read() :: :ok
end
