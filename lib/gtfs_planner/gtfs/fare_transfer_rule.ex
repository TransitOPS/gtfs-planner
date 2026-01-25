defmodule GtfsPlanner.Gtfs.FareTransferRule do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "fare_transfer_rules" do
    field :from_leg_group_id, :string
    field :to_leg_group_id, :string
    field :transfer_count, :integer
    field :duration_limit, :integer
    field :duration_limit_type, :integer
    field :fare_transfer_type, :integer
    field :fare_product_id, :string

    belongs_to :organization, GtfsPlanner.Organizations.Organization,
      foreign_key: :organization_id

    field :gtfs_version_id, :binary_id

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          organization_id: Ecto.UUID.t(),
          gtfs_version_id: Ecto.UUID.t(),
          from_leg_group_id: String.t() | nil,
          to_leg_group_id: String.t() | nil,
          transfer_count: integer() | nil,
          duration_limit: integer() | nil,
          duration_limit_type: integer() | nil,
          fare_transfer_type: integer(),
          fare_product_id: String.t() | nil,
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  @doc "Creates a changeset for a fare transfer rule."
  def changeset(fare_transfer_rule, attrs) do
    fare_transfer_rule
    |> cast(attrs, [
      :from_leg_group_id,
      :to_leg_group_id,
      :transfer_count,
      :duration_limit,
      :duration_limit_type,
      :fare_transfer_type,
      :fare_product_id,
      :organization_id,
      :gtfs_version_id
    ])
    |> validate_required([:fare_transfer_type, :organization_id, :gtfs_version_id])
    |> validate_inclusion(:fare_transfer_type, 0..2)
    |> validate_inclusion(:duration_limit_type, 0..3)
    |> unique_constraint([:organization_id, :gtfs_version_id, :from_leg_group_id, :to_leg_group_id, :fare_product_id, :transfer_count])
    |> foreign_key_constraint(:organization_id)
  end
end