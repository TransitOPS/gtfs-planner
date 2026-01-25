defmodule GtfsPlanner.Gtfs.FareLegJoinRule do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "fare_leg_join_rules" do
    field :from_network_id, :string
    field :to_network_id, :string
    field :from_stop_id, :string
    field :to_stop_id, :string

    belongs_to :organization, GtfsPlanner.Organizations.Organization,
      foreign_key: :organization_id

    field :gtfs_version_id, :binary_id

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          organization_id: Ecto.UUID.t(),
          gtfs_version_id: Ecto.UUID.t(),
          from_network_id: String.t() | nil,
          to_network_id: String.t() | nil,
          from_stop_id: String.t() | nil,
          to_stop_id: String.t() | nil,
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  @doc "Creates a changeset for a fare leg join rule."
  def changeset(fare_leg_join_rule, attrs) do
    fare_leg_join_rule
    |> cast(attrs, [
      :from_network_id,
      :to_network_id,
      :from_stop_id,
      :to_stop_id,
      :organization_id,
      :gtfs_version_id
    ])
    |> validate_required([:organization_id, :gtfs_version_id])
    |> unique_constraint([:organization_id, :gtfs_version_id, :from_network_id, :to_network_id, :from_stop_id, :to_stop_id])
    |> foreign_key_constraint(:organization_id)
  end
end