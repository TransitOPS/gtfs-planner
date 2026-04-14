defmodule GtfsPlanner.Gtfs.Pathway do
  use Ecto.Schema
  import Ecto.Changeset

  @pathway_modes %{
    walkway: 1,
    stairs: 2,
    moving_sidewalk: 3,
    escalator: 4,
    elevator: 5,
    fare_gate: 6,
    exit_gate: 7
  }

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          organization_id: Ecto.UUID.t(),
          gtfs_version_id: Ecto.UUID.t(),
          pathway_id: String.t(),
          pathway_mode: integer(),
          is_bidirectional: boolean(),
          traversal_time: integer() | nil,
          length: Decimal.t() | nil,
          stair_count: integer() | nil,
          max_slope: Decimal.t() | nil,
          min_width: Decimal.t() | nil,
          signposted_as: String.t() | nil,
          reversed_signposted_as: String.t() | nil,
          field_notes: String.t() | nil,
          field_completed_at: DateTime.t() | nil,
          from_stop_id: String.t(),
          to_stop_id: String.t(),
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "pathways" do
    field :pathway_id, :string
    field :pathway_mode, :integer
    field :is_bidirectional, :boolean, default: true
    field :traversal_time, :integer
    field :length, :decimal
    field :stair_count, :integer
    field :max_slope, :decimal
    field :min_width, :decimal
    field :signposted_as, :string
    field :reversed_signposted_as, :string
    field :field_notes, :string
    field :field_completed_at, :utc_datetime_usec

    belongs_to :organization, GtfsPlanner.Organizations.Organization,
      foreign_key: :organization_id

    belongs_to :gtfs_version, GtfsPlanner.Versions.GtfsVersion

    field :from_stop_id, :string
    field :to_stop_id, :string

    field :from_stop, :map, virtual: true
    field :to_stop, :map, virtual: true

    timestamps(type: :utc_datetime_usec)
  end

  def pathway_modes, do: @pathway_modes

  def mode_label(mode) do
    case mode do
      1 -> "Walkway"
      2 -> "Stairs"
      3 -> "Moving Sidewalk"
      4 -> "Escalator"
      5 -> "Elevator"
      6 -> "Fare Gate"
      7 -> "Exit Gate"
      _ -> "Unknown"
    end
  end

  def changeset(pathway, attrs) do
    pathway
    |> cast(attrs, [
      :pathway_id,
      :pathway_mode,
      :is_bidirectional,
      :traversal_time,
      :length,
      :stair_count,
      :max_slope,
      :min_width,
      :signposted_as,
      :reversed_signposted_as,
      :field_notes,
      :field_completed_at,
      :organization_id,
      :gtfs_version_id,
      :from_stop_id,
      :to_stop_id
    ])
    |> validate_required([
      :pathway_id,
      :pathway_mode,
      :organization_id,
      :gtfs_version_id,
      :from_stop_id,
      :to_stop_id
    ])
    |> validate_inclusion(:pathway_mode, 1..7)
    |> unique_constraint([:organization_id, :gtfs_version_id, :pathway_id])
    |> foreign_key_constraint(:organization_id)
  end
end
