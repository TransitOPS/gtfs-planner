defmodule GtfsPlanner.Home.Attention do
  @moduledoc """
  Builds the homepage's "Needs attention" items from facts the page already read.

  `build/2` is pure. Callers pass the coverage claim, the agency-local today,
  the organization's stopped import runs and the latest feed check, and the
  builder returns the items in the order the page renders them:

    1. one service warning when the version's calendars end within 14 days or
       have already ended;
    2. one item per stopped import run;
    3. one item when the latest feed check found errors.

  The service warning comes only from the version-wide calendar coverage
  (`{:through, last_date}`). Calendar gaps never raise an item, so a version
  whose weekdays and Saturdays skip Sunday reports nothing, and an unreadable
  calendar read has no coverage and therefore no service item. The `:pathways`
  product omits the service item entirely: a Pathways homepage reads no
  calendars.

  The builder never writes and never reconciles an import lease. `Home` filters
  the organization's runs to the stopped states before calling it.
  """

  alias GtfsPlanner.Gtfs.Import.Run
  alias GtfsPlanner.Validations.ValidationRun

  @ends_soon_days 14

  @type item ::
          %{kind: :service_ends, last_date: Date.t(), days: non_neg_integer()}
          | %{kind: :service_ended, last_date: Date.t()}
          | %{
              kind: :stopped_import,
              run_id: Ecto.UUID.t(),
              version_name: String.t() | nil,
              failed_file: String.t() | nil,
              failed_row: integer() | nil
            }
          | %{kind: :check_errors, run_id: Ecto.UUID.t(), errors: pos_integer(), at: DateTime.t()}

  @doc """
  Returns the attention items for one product.

  `facts` carries the `coverage` from `Home.planner_status/2`, the agency-local
  `today`, the stopped `imports` and the latest `check`. Service items come
  first, then the import items in the caller's order, then the check item.
  """
  @spec build(
          %{
            coverage: term(),
            today: Date.t(),
            imports: [Run.t()],
            check: ValidationRun.t() | nil
          },
          :planner | :pathways
        ) :: [item()]
  def build(facts, product) do
    service_items(facts, product) ++ import_items(facts.imports) ++ check_items(facts.check)
  end

  defp service_items(_facts, :pathways), do: []

  defp service_items(%{coverage: {:through, last_date}, today: today}, :planner) do
    days = Date.diff(last_date, today)

    cond do
      days < 0 -> [%{kind: :service_ended, last_date: last_date}]
      days <= @ends_soon_days -> [%{kind: :service_ends, last_date: last_date, days: days}]
      true -> []
    end
  end

  defp service_items(_facts, :planner), do: []

  defp import_items(imports) do
    Enum.map(imports, fn run ->
      %{
        kind: :stopped_import,
        run_id: run.id,
        version_name: run.version_name,
        failed_file: run.failed_file,
        failed_row: run.failed_row
      }
    end)
  end

  # The check's time is the run's start: `latest_feed_check/2` orders by it and
  # the existing validation screens display it, while `completed_at` may be nil.
  defp check_items(%ValidationRun{errors_count: errors} = run) when errors > 0 do
    [%{kind: :check_errors, run_id: run.id, errors: errors, at: run.started_at}]
  end

  defp check_items(_check), do: []
end
