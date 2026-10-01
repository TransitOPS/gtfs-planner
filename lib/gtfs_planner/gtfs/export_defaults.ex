defmodule GtfsPlanner.Gtfs.ExportDefaults do
  @moduledoc """
  Read and write the organization's GTFS export defaults.

  `get/1` returns the stored row, or the defaults for an organization that has
  none, without inserting. `update/3` upserts the organization's single row, so
  a first save and a later save take one path; it applies the submitted attrs to
  the current values, so a save that omits a setting keeps that setting.

  Every read and write filters on `organization_id` (R10); nothing here is
  version-scoped, because the defaults apply to every version of the
  organization.
  """

  alias GtfsPlanner.Authorization
  alias GtfsPlanner.Gtfs.ExportDefault
  alias GtfsPlanner.Repo

  @spec get(Ecto.UUID.t()) :: ExportDefault.t()
  def get(organization_id) do
    Repo.get_by(ExportDefault, organization_id: organization_id) ||
      %ExportDefault{organization_id: organization_id}
  end

  @spec update(Ecto.UUID.t(), map(), map()) ::
          {:ok, ExportDefault.t()} | {:error, Ecto.Changeset.t() | :forbidden}
  def update(organization_id, actor, attrs) do
    actor_id = if is_map(actor), do: Map.get(actor, :id), else: nil

    case Repo.transaction(fn ->
           Authorization.lock_editor!(%{
             actor_id: actor_id,
             organization_id: organization_id
           })

           organization_id
           |> get()
           |> ExportDefault.changeset(attrs)
           |> Repo.insert(
             mode: :savepoint,
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
         end) do
      {:ok, result} -> result
      {:error, :forbidden} -> {:error, :forbidden}
    end
  end
end
