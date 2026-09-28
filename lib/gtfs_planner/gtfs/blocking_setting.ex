defmodule GtfsPlanner.Gtfs.BlockingSetting do
  @moduledoc """
  Schema for the per-version minimum layover used by the Blocks page.

  One row is stored per organization and GTFS version; a version with no row
  uses the default of 5 minutes.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "blocking_settings" do
    field :min_layover_minutes, :integer, default: 5

    belongs_to :organization, GtfsPlanner.Organizations.Organization,
      foreign_key: :organization_id

    belongs_to :gtfs_version, GtfsPlanner.Versions.GtfsVersion

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          organization_id: Ecto.UUID.t(),
          gtfs_version_id: Ecto.UUID.t(),
          min_layover_minutes: integer(),
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  @doc """
  Changeset for the minimum layover.

  Only `min_layover_minutes` is cast, so `organization_id` and `gtfs_version_id`
  in submitted parameters are ignored; the caller sets those on the struct. A
  blank submitted value is a field error rather than the default: the number
  input has no empty value of its own.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(setting, attrs) do
    setting
    |> cast(attrs, [:min_layover_minutes], empty_values: [])
    |> validate_required([:min_layover_minutes])
    |> validate_number(:min_layover_minutes,
      greater_than_or_equal_to: 0,
      less_than_or_equal_to: 120,
      message: "must be a whole number between 0 and 120"
    )
    |> check_constraint(:min_layover_minutes,
      name: :min_layover_range,
      message: "must be a whole number between 0 and 120"
    )
  end
end
