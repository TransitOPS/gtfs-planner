defmodule GtfsPlanner.Gtfs.FareAttribute do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "fare_attributes" do
    field :fare_id, :string
    field :price, :decimal
    field :currency_type, :string
    field :payment_method, :integer
    field :transfers, :integer
    field :agency_id, :string
    field :transfer_duration, :integer

    belongs_to :organization, GtfsPlanner.Organizations.Organization,
      foreign_key: :organization_id

    field :gtfs_version_id, :binary_id

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          organization_id: Ecto.UUID.t(),
          gtfs_version_id: Ecto.UUID.t(),
          fare_id: String.t(),
          price: Decimal.t(),
          currency_type: String.t(),
          payment_method: integer(),
          transfers: integer() | nil,
          agency_id: String.t() | nil,
          transfer_duration: integer() | nil,
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  @doc "Creates a changeset for a fare attribute."
  def changeset(fare_attribute, attrs) do
    fare_attribute
    |> cast(attrs, [
      :fare_id,
      :price,
      :currency_type,
      :payment_method,
      :transfers,
      :agency_id,
      :transfer_duration,
      :organization_id,
      :gtfs_version_id
    ])
    |> validate_required([:fare_id, :price, :currency_type, :payment_method, :organization_id, :gtfs_version_id])
    |> validate_number(:price, greater_than: 0)
    |> validate_inclusion(:payment_method, 0..1)
    |> validate_inclusion(:transfers, [0, 1, 2])
    |> unique_constraint([:organization_id, :gtfs_version_id, :fare_id])
    |> foreign_key_constraint(:organization_id)
  end
end