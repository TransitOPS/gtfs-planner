defmodule GtfsPlanner.Validations do
  @moduledoc """
  The Validations context for managing GTFS validation runs.
  """

  import Ecto.Query

  alias GtfsPlanner.Repo
  alias GtfsPlanner.Validations.ValidationRun

  @doc """
  Creates a new validation run with status "started".

  ## Examples

      iex> create_validation_run(org_id, version_id, "mobility_data")
      {:ok, %ValidationRun{}}

      iex> create_validation_run(nil, version_id, "mobility_data")
      {:error, %Ecto.Changeset{}}

  """
  def create_validation_run(organization_id, gtfs_version_id, run_type) do
    %ValidationRun{
      organization_id: organization_id,
      gtfs_version_id: gtfs_version_id,
      started_at: DateTime.utc_now()
    }
    |> ValidationRun.changeset(%{
      run_type: run_type,
      status: "started"
    })
    |> Repo.insert()
  end

  @doc """
  Gets a single validation run, raising if not found.

  ## Examples

      iex> get_validation_run!(id)
      %ValidationRun{}

      iex> get_validation_run!("invalid")
      ** (Ecto.NoResultsError)

  """
  def get_validation_run!(id) do
    Repo.get!(ValidationRun, id)
  end

  @doc """
  Gets a single validation run, returning nil if not found.

  ## Examples

      iex> get_validation_run(id)
      %ValidationRun{}

      iex> get_validation_run("invalid")
      nil

  """
  def get_validation_run(id) do
    Repo.get(ValidationRun, id)
  end

  @doc """
  Lists validation runs for a given organization and GTFS version.
  Results are ordered by started_at descending and limited to 20.

  ## Examples

      iex> list_validation_runs(org_id, version_id)
      [%ValidationRun{}, ...]

  """
  def list_validation_runs(organization_id, gtfs_version_id) do
    ValidationRun
    |> where([vr], vr.organization_id == ^organization_id)
    |> where([vr], vr.gtfs_version_id == ^gtfs_version_id)
    |> order_by([vr], desc: vr.started_at)
    |> limit(20)
    |> Repo.all()
  end

  @doc """
  Lists recent completed or failed validation runs for a given organization and GTFS version.
  Results are ordered by started_at descending and limited to the specified number.

  ## Examples

      iex> list_recent_validation_runs(org_id, version_id, 5)
      [%ValidationRun{}, ...]

  """
  def list_recent_validation_runs(organization_id, gtfs_version_id, limit \\ 5) do
    ValidationRun
    |> where([vr], vr.organization_id == ^organization_id)
    |> where([vr], vr.gtfs_version_id == ^gtfs_version_id)
    |> where([vr], vr.status in ["completed", "failed"])
    |> order_by([vr], desc: vr.started_at)
    |> limit(^limit)
    |> Repo.all()
  end

  @doc """
  Marks a validation run as running.

  ## Examples

      iex> mark_running(run)
      {:ok, %ValidationRun{status: "running"}}

  """
  def mark_running(run) do
    run
    |> ValidationRun.changeset(%{status: "running"})
    |> Repo.update()
  end

  @doc """
  Marks a validation run as completed and stores the result.

  ## Examples

      iex> mark_completed(run, result)
      {:ok, %ValidationRun{status: "completed"}}

  """
  def mark_completed(run, result) do
    result_json = %{
      "notices" => result.notices
    }

    run
    |> ValidationRun.changeset(%{
      status: "completed",
      errors_count: result.summary.errors,
      warnings_count: result.summary.warnings,
      infos_count: result.summary.infos,
      duration_ms: result.duration_ms,
      result_json: result_json,
      completed_at: DateTime.utc_now()
    })
    |> Repo.update()
  end

  @doc """
  Marks a validation run as failed and stores the error details.

  ## Examples

      iex> mark_failed(run, reason)
      {:ok, %ValidationRun{status: "failed"}}

  """
  def mark_failed(run, reason) do
    run
    |> ValidationRun.changeset(%{
      status: "failed",
      error_details: inspect(reason),
      completed_at: DateTime.utc_now()
    })
    |> Repo.update()
  end
end
