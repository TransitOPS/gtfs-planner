defmodule GtfsPlanner.Gtfs.Pathway do
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          organization_id: Ecto.UUID.t(),
          gtfs_version_id: Ecto.UUID.t(),
          pathway_id: String.t(),
          from_stop_id: Ecto.UUID.t(),
          to_stop_id: Ecto.UUID.t(),
          pathway_mode: integer(),
          is_bidirectional: boolean(),
          traversal_time: integer() | nil,
          length: Decimal.t() | nil,
          stair_count: integer() | nil,
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

    belongs_to :organization, GtfsPlanner.Organizations.Organization,
      foreign_key: :organization_id
    belongs_to :gtfs_version, GtfsPlanner.Versions.GtfsVersion
    belongs_to :from_stop, GtfsPlanner.Gtfs.Stop,
      foreign_key: :from_stop_id
    belongs_to :to_stop, GtfsPlanner.Gtfs.Stop,
      foreign_key: :to_stop_id

    timestamps(type: :utc_datetime_usec)
  end

  @pathway_modes %{
    1 => :walkway,
    2 => :stairs,
    3 => :moving_sidewalk,
    4 => :escalator,
    5 => :elevator,
    6 => :fare_gate,
    7 => :exit_gate
  }

  @doc "Returns the map of pathway mode integers to atoms."
  def pathway_modes, do: @pathway_modes

  @doc "Creates a changeset for a pathway."
  def changeset(pathway, attrs) do
    pathway
    |> cast(attrs, [:pathway_id, :from_stop_id, :to_stop_id, :pathway_mode, :is_bidirectional, :traversal_time, :length, :stair_count, :organization_id, :gtfs_version_id])
    |> validate_required([:pathway_id, :from_stop_id, :to_stop_id, :pathway_mode, :is_bidirectional, :organization_id, :gtfs_version_id])
    |> validate_inclusion(:pathway_mode, 1..7)
    |> unique_constraint([:organization_id, :gtfs_version_id, :pathway_id], name: :pathways_organization_id_gtfs_version_id_pathway_id_index)
    |> foreign_key_constraint(:organization_id, name: :pathways_organization_id_fkey)
    |> foreign_key_constraint(:gtfs_version_id, name: :pathways_gtfs_version_id_fkey)
    |> foreign_key_constraint(:from_stop_id, name: :pathways_from_stop_id_fkey)
    |> foreign_key_constraint(:to_stop_id, name: :pathways_to_stop_id_fkey)
  end
end
