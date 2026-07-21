defmodule GtfsPlanner.Gtfs.BrowserValidator do
  @moduledoc false

  @behaviour GtfsPlanner.Gtfs.ValidatorBehaviour

  alias GtfsPlanner.Gtfs.Validator.Result
  alias GtfsPlanner.Validations

  @impl true
  def validate(_organization_id, _gtfs_version_id, opts) do
    run = opts |> Keyword.fetch!(:validation_run_id) |> Validations.get_validation_run!()
    {:ok, running_run} = Validations.mark_running(run)

    result = %Result{
      summary: %{errors: 0, warnings: 1, infos: 2},
      notices: [],
      duration_ms: 1,
      validated_at: DateTime.utc_now()
    }

    {:ok, _completed_run} = Validations.mark_completed(running_run, result)
    {:ok, result}
  end
end
