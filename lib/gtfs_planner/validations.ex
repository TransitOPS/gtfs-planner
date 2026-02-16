defmodule GtfsPlanner.Validations do
  @moduledoc """
  The Validations context for managing GTFS validation runs.
  """

  import Ecto.Query

  alias GtfsPlanner.Repo
  alias GtfsPlanner.Validations.ValidationRun
  alias GtfsPlanner.Validations.WalkabilityTest

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

  # --- Walkability Tests ---

  @doc """
  Lists walkability tests for a given organization.
  Results are ordered by inserted_at descending.

  ## Examples

      iex> list_walkability_tests(org_id)
      [%WalkabilityTest{}, ...]

  """
  def list_walkability_tests(organization_id) do
    WalkabilityTest
    |> where([wt], wt.organization_id == ^organization_id)
    |> order_by([wt], desc: wt.inserted_at)
    |> Repo.all()
  end

  @doc """
  Lists walkability tests for a given organization and stop ids.
  Results are ordered by inserted_at descending.
  """
  def list_walkability_tests_for_stop_ids(_organization_id, []), do: []

  def list_walkability_tests_for_stop_ids(organization_id, stop_ids) do
    WalkabilityTest
    |> where([wt], wt.organization_id == ^organization_id and wt.stop_id in ^stop_ids)
    |> order_by([wt], desc: wt.inserted_at)
    |> Repo.all()
  end

  @doc """
  Gets a single walkability test, raising if not found.

  ## Examples

      iex> get_walkability_test!(id)
      %WalkabilityTest{}

      iex> get_walkability_test!("invalid")
      ** (Ecto.NoResultsError)

  """
  def get_walkability_test!(id) do
    Repo.get!(WalkabilityTest, id)
  end

  @doc """
  Gets a single walkability test, returning nil if not found.
  """
  def get_walkability_test(id) do
    Repo.get(WalkabilityTest, id)
  end

  @doc """
  Creates a walkability test for a given organization.

  ## Examples

      iex> create_walkability_test(org_id, %{stop_id: "stop_123", address: "123 Main St", address_lat: "40.7128", address_lon: "-74.0060"})
      {:ok, %WalkabilityTest{}}

      iex> create_walkability_test(org_id, %{})
      {:error, %Ecto.Changeset{}}

  """
  def create_walkability_test(organization_id, attrs) do
    %WalkabilityTest{organization_id: organization_id}
    |> WalkabilityTest.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Updates a walkability test.

  ## Examples

      iex> update_walkability_test(walkability_test, %{address: "456 Oak Ave"})
      {:ok, %WalkabilityTest{}}

      iex> update_walkability_test(walkability_test, %{stop_id: nil})
      {:error, %Ecto.Changeset{}}

  """
  def update_walkability_test(walkability_test, attrs) do
    walkability_test
    |> WalkabilityTest.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Deletes a walkability test.

  ## Examples

      iex> delete_walkability_test(walkability_test)
      {:ok, %WalkabilityTest{}}

      iex> delete_walkability_test(walkability_test)
      {:error, %Ecto.Changeset{}}

  """
  def delete_walkability_test(walkability_test) do
    Repo.delete(walkability_test)
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking walkability test changes.

  ## Examples

      iex> change_walkability_test(walkability_test)
      %Ecto.Changeset{data: %WalkabilityTest{}}

  """
  def change_walkability_test(walkability_test, attrs \\ %{}) do
    WalkabilityTest.changeset(walkability_test, attrs)
  end

  @doc """
  Returns a map of stop_id => test count for stops that have walkability tests.
  """
  def stop_ids_with_walkability_tests(_organization_id, []), do: %{}

  def stop_ids_with_walkability_tests(organization_id, stop_ids) do
    WalkabilityTest
    |> where([wt], wt.organization_id == ^organization_id and wt.stop_id in ^stop_ids)
    |> group_by([wt], wt.stop_id)
    |> select([wt], {wt.stop_id, count(wt.id)})
    |> Repo.all()
    |> Map.new()
  end
end
