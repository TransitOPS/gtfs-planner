defmodule GtfsPlanner.Gtfs.Blocking do
  @moduledoc """
  Scoped reads and writes for the Blocks page.

  Every function is scoped to one organization and GTFS version: organization,
  version and actor come from arguments, never from submitted parameters. The
  minimum layover is stored per published version, read as a default without
  writing a row, and validated before it reaches the table.
  """

  import Ecto.Query, warn: false

  alias GtfsPlanner.Gtfs.BlockingSetting
  alias GtfsPlanner.Repo
  alias GtfsPlanner.Versions

  @default_min_layover_minutes 5

  @doc """
  Returns the minimum layover for one organization's GTFS version.

  A version with no stored row returns the default and stores nothing.

  ## Examples

      iex> get_settings(organization_id, gtfs_version_id)
      %{min_layover_minutes: 5}
  """
  @spec get_settings(Ecto.UUID.t(), Ecto.UUID.t()) :: %{min_layover_minutes: 0..120}
  def get_settings(organization_id, gtfs_version_id) do
    case Repo.one(settings_query(organization_id, gtfs_version_id)) do
      %{min_layover_minutes: minutes} -> %{min_layover_minutes: minutes}
      nil -> %{min_layover_minutes: @default_min_layover_minutes}
    end
  end

  @doc """
  Returns the changeset rendered by the minimum layover form.

  `settings` is a value map from `get_settings/2` and `attrs` are the submitted
  parameters; an invalid value carries the field error.
  """
  @spec change_settings(map(), map()) :: Ecto.Changeset.t()
  def change_settings(settings, attrs) do
    %BlockingSetting{}
    |> Ecto.Changeset.change(
      min_layover_minutes: Map.get(settings, :min_layover_minutes, @default_min_layover_minutes)
    )
    |> BlockingSetting.changeset(attrs)
  end

  @doc """
  Stores the minimum layover for one organization's published GTFS version.

  Returns `{:error, :not_found}` when the version is unpublished or belongs to
  another organization, and `{:error, changeset}` when the value is not a whole
  number from 0 to 120. One row is kept per organization and version, so a
  repeated save replaces the stored value.
  """
  @spec update_settings(Ecto.UUID.t(), Ecto.UUID.t(), map()) ::
          {:ok, BlockingSetting.t()} | {:error, Ecto.Changeset.t() | :not_found}
  def update_settings(organization_id, gtfs_version_id, attrs) do
    if Versions.published_gtfs_version_for_org?(organization_id, gtfs_version_id) do
      %BlockingSetting{organization_id: organization_id, gtfs_version_id: gtfs_version_id}
      |> BlockingSetting.changeset(attrs)
      |> Repo.insert(
        on_conflict: {:replace, [:min_layover_minutes, :updated_at]},
        conflict_target: [:organization_id, :gtfs_version_id],
        returning: true
      )
    else
      {:error, :not_found}
    end
  end

  defp settings_query(organization_id, gtfs_version_id) do
    from(s in BlockingSetting,
      where: s.organization_id == ^organization_id and s.gtfs_version_id == ^gtfs_version_id,
      select: %{min_layover_minutes: s.min_layover_minutes}
    )
  end
end
