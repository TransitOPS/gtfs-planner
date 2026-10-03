defmodule GtfsPlanner.Gtfs.BrowserValidator do
  @moduledoc false

  @behaviour GtfsPlanner.Gtfs.ValidatorBehaviour

  alias GtfsPlanner.Gtfs.Validator.Result

  # Returns a fixed result. `Validations.Runner` claims the run and writes the
  # terminal state, exactly as it does around the real validator.
  @impl true
  def validate(_organization_id, _gtfs_version_id, _opts) do
    {:ok, fixed_result()}
  end

  # The artifact review path returns the same fixed report, so a browser
  # journey's publication preview sees the same result the real validator
  # persists for a database export.
  @impl true
  def validate_artifact(_organization_id, _validation_run_id, _opts) do
    {:ok, fixed_result()}
  end

  defp fixed_result do
    %Result{
      summary: %{errors: 0, warnings: 1, infos: 2},
      notices: [],
      duration_ms: 1,
      validated_at: DateTime.utc_now()
    }
  end
end
