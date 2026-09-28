defmodule GtfsPlanner.Gtfs.BlockingSetting do
  @moduledoc """
  Schema for the per-version blocking settings used by the Blocks page.

  One row is stored per organization and GTFS version; a version with no row
  uses the defaults (5 minutes minimum layover, no block-length or piece limits,
  any interlining, 30 km/h estimated deadhead speed at 1.3 circuity). The
  changeset still validates only `min_layover_minutes`; the remaining settings
  are widened with their changeset in a later step.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "blocking_settings" do
    field :min_layover_minutes, :integer, default: 5
    field :max_block_minutes, :integer
    field :pull_out_buffer_minutes, :integer, default: 0
    field :interlining, Ecto.Enum, values: [:any, :same_stop, :none], default: :any
    field :deadhead_speed_kmh, :integer, default: 30
    field :deadhead_circuity, :decimal, default: Decimal.new("1.3")
    field :max_piece_minutes, :integer

    belongs_to :default_garage, GtfsPlanner.Operations.Garage

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
          max_block_minutes: integer() | nil,
          pull_out_buffer_minutes: integer(),
          interlining: :any | :same_stop | :none,
          default_garage_id: Ecto.UUID.t() | nil,
          deadhead_speed_kmh: integer(),
          deadhead_circuity: Decimal.t(),
          max_piece_minutes: integer() | nil,
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
