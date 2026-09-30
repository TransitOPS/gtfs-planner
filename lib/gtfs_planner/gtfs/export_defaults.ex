defmodule GtfsPlanner.Gtfs.ExportDefaults do
  @moduledoc """
  Read and write the organization's GTFS export defaults.

  `get/1` returns the stored row, or the defaults for an organization that has
  none, without inserting. `update/2` upserts the organization's single row, so
  a first save and a later save take one path; it applies the submitted attrs to
  the current values, so a save that omits a setting keeps that setting.

  Every read and write filters on `organization_id` (R10); nothing here is
  version-scoped, because the defaults apply to every version of the
  organization.
  """

  alias GtfsPlanner.Gtfs.ExportDefault
  alias GtfsPlanner.Repo

  @spec get(Ecto.UUID.t()) :: ExportDefault.t()
  def get(organization_id) do
    Repo.get_by(ExportDefault, organization_id: organization_id) ||
      %ExportDefault{organization_id: organization_id}
  end

  @spec update(Ecto.UUID.t(), map()) ::
          {:ok, ExportDefault.t()} | {:error, Ecto.Changeset.t()}
  def update(organization_id, attrs) do
    organization_id
    |> get()
    |> ExportDefault.changeset(attrs)
    |> Repo.insert(
      on_conflict:
        {:replace,
         [
           :include_flex,
           :realtime_source,
           :estimate_missing_times,
           :estimate_method,
           :updated_at
         ]},
      conflict_target: :organization_id,
      returning: true
    )
  end
end
