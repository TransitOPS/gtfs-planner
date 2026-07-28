defmodule GtfsPlanner.Validations do
  @moduledoc """
  The Validations context for managing GTFS validation runs.

  Historical pathways and OTP results are read through `Validations.Legacy`.
  """

  import Ecto.Query

  alias GtfsPlanner.Repo
  alias GtfsPlanner.Validations.{ValidationRun, WalkabilityTest}

  @doc """
  Creates a new validation run with status "started".
  """
  @spec create_validation_run(Ecto.UUID.t(), Ecto.UUID.t(), String.t()) ::
          {:ok, ValidationRun.t()} | {:error, Ecto.Changeset.t()}
  def create_validation_run(organization_id, gtfs_version_id, run_type) do
    %ValidationRun{
      organization_id: organization_id,
      gtfs_version_id: gtfs_version_id,
      started_at: DateTime.utc_now()
    }
    |> ValidationRun.changeset(%{run_type: run_type, status: "started"})
    |> Repo.insert()
  end

  @doc """
  Gets a single validation run, raising if not found.
  """
  @spec get_validation_run!(Ecto.UUID.t()) :: ValidationRun.t()
  def get_validation_run!(id), do: Repo.get!(ValidationRun, id)

  @doc """
  Gets a single validation run, returning nil if not found.
  """
  @spec get_validation_run(Ecto.UUID.t()) :: ValidationRun.t() | nil
  def get_validation_run(id), do: Repo.get(ValidationRun, id)

  @doc """
  Lists validation runs for a given organization and GTFS version.

  Results are ordered by started_at descending and limited to 20.
  """
  @spec list_validation_runs(Ecto.UUID.t(), Ecto.UUID.t()) :: [ValidationRun.t()]
  def list_validation_runs(organization_id, gtfs_version_id) do
    ValidationRun
    |> where([run], run.organization_id == ^organization_id)
    |> where([run], run.gtfs_version_id == ^gtfs_version_id)
    |> order_by([run], desc: run.started_at)
    |> limit(20)
    |> Repo.all()
  end

  @doc """
  Lists recent completed or failed validation runs for an organization and GTFS version.
  """
  @spec list_recent_validation_runs(Ecto.UUID.t(), Ecto.UUID.t(), pos_integer()) :: [
          ValidationRun.t()
        ]
  def list_recent_validation_runs(organization_id, gtfs_version_id, limit \\ 5) do
    ValidationRun
    |> where([run], run.organization_id == ^organization_id)
    |> where([run], run.gtfs_version_id == ^gtfs_version_id)
    |> where([run], run.status in ["completed", "failed"])
    |> order_by([run], desc: run.started_at)
    |> limit(^limit)
    |> Repo.all()
  end

  @doc """
  Marks a validation run as running.
  """
  @spec mark_running(ValidationRun.t()) ::
          {:ok, ValidationRun.t()} | {:error, Ecto.Changeset.t()}
  def mark_running(run) do
    run
    |> ValidationRun.changeset(%{status: "running"})
    |> Repo.update()
  end

  @doc """
  Marks a validation run as completed and stores the validator result.
  """
  @spec mark_completed(ValidationRun.t(), %{
          summary: map(),
          notices: list(),
          duration_ms: integer()
        }) ::
          {:ok, ValidationRun.t()} | {:error, Ecto.Changeset.t() | Ecto.StaleEntryError.t()}
  def mark_completed(run, result) do
    run
    |> ValidationRun.changeset(%{
      status: "completed",
      errors_count: result.summary.errors,
      warnings_count: result.summary.warnings,
      infos_count: result.summary.infos,
      duration_ms: result.duration_ms,
      result_json: %{"notices" => result.notices},
      completed_at: DateTime.utc_now()
    })
    |> Repo.update(stale_error_field: :id)
  end

  @doc """
  Marks a validation run as failed and stores the error details.
  """
  @spec mark_failed(ValidationRun.t(), term()) ::
          {:ok, ValidationRun.t()} | {:error, Ecto.Changeset.t() | Ecto.StaleEntryError.t()}
  def mark_failed(run, reason) do
    run
    |> ValidationRun.changeset(%{
      status: "failed",
      error_details: inspect(reason),
      completed_at: DateTime.utc_now()
    })
    |> Repo.update(stale_error_field: :id)
  end

  @doc """
  Lists walkability tests for an organization and GTFS version in deterministic order.
  """
  @spec list_walkability_tests(Ecto.UUID.t(), Ecto.UUID.t()) :: [WalkabilityTest.t()]
  def list_walkability_tests(organization_id, gtfs_version_id) do
    WalkabilityTest
    |> where([test], test.organization_id == ^organization_id)
    |> where([test], test.gtfs_version_id == ^gtfs_version_id)
    |> order_by([test], asc: test.stop_id, asc: test.address, asc: test.id)
    |> Repo.all()
  end

  @doc """
  Lists walkability tests for an organization, GTFS version, and stop ids.
  """
  @spec list_walkability_tests_for_stop_ids(Ecto.UUID.t(), Ecto.UUID.t(), [String.t()]) :: [
          WalkabilityTest.t()
        ]
  def list_walkability_tests_for_stop_ids(_organization_id, _gtfs_version_id, []), do: []

  def list_walkability_tests_for_stop_ids(organization_id, gtfs_version_id, stop_ids) do
    WalkabilityTest
    |> where(
      [test],
      test.organization_id == ^organization_id and test.gtfs_version_id == ^gtfs_version_id and
        test.stop_id in ^stop_ids
    )
    |> order_by([test], desc: test.inserted_at)
    |> Repo.all()
  end

  @doc """
  Gets a single walkability test, raising if not found.
  """
  @spec get_walkability_test!(Ecto.UUID.t()) :: WalkabilityTest.t()
  def get_walkability_test!(id), do: Repo.get!(WalkabilityTest, id)

  @doc """
  Gets a single walkability test, returning nil if not found.
  """
  @spec get_walkability_test(Ecto.UUID.t()) :: WalkabilityTest.t() | nil
  def get_walkability_test(id), do: Repo.get(WalkabilityTest, id)
end
