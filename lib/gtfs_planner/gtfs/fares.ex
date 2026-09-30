defmodule GtfsPlanner.Gtfs.Fares do
  @moduledoc """
  The facade over the fare tables a version's fares are edited in.

  A version is *managed* when a `fare_version_settings` row exists for it with
  `managed_at` set. `managed?/2` and `settings/2` are its read side: the export
  and the fare editors ask this module rather than querying the table, so the
  unscoped `get_*!` helpers in `GtfsPlanner.Gtfs` are never used for fare rows.
  Both functions filter by `organization_id` and `gtfs_version_id` together, so
  a version of another organization that carries a settings row is never managed
  (INV-5), and an unmanaged version exports its imported files unchanged.

  The remaining writers of this package — `Fares.Conversion`,
  `Fares.Transfers` and `Fares.Normalize` — are added by later steps; this
  module owns the managed flag and nothing else yet.
  """

  import Ecto.Query, warn: false

  alias GtfsPlanner.Gtfs.FareVersionSetting
  alias GtfsPlanner.Repo

  @doc """
  Whether the version's fares are managed here.

  True exactly when a `fare_version_settings` row exists for this organization
  and version with `managed_at` set. A settings row of another organization or
  another version never answers for this pair.
  """
  @spec managed?(Ecto.UUID.t(), Ecto.UUID.t()) :: boolean()
  def managed?(organization_id, gtfs_version_id) do
    query =
      from(setting in FareVersionSetting,
        where:
          setting.organization_id == ^organization_id and
            setting.gtfs_version_id == ^gtfs_version_id and
            not is_nil(setting.managed_at)
      )

    Repo.exists?(query)
  end

  @doc """
  The version's settings row, or `nil` when the version is unmanaged.

  The row carries `older_format` — `"derived"` or `"imported"` — and the
  `conversion_operation_id` a conversion recorded, so undo can find it again.
  """
  @spec settings(Ecto.UUID.t(), Ecto.UUID.t()) :: FareVersionSetting.t() | nil
  def settings(organization_id, gtfs_version_id) do
    FareVersionSetting
    |> where(
      [setting],
      setting.organization_id == ^organization_id and
        setting.gtfs_version_id == ^gtfs_version_id
    )
    |> Repo.one()
  end
end
