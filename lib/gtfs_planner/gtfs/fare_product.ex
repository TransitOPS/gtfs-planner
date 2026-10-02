defmodule GtfsPlanner.Gtfs.FareProduct do
  use Ecto.Schema
  import Ecto.Changeset
  import GtfsPlanner.ChangesetHelpers

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "fare_products" do
    field :fare_product_id, :string
    field :fare_product_name, :string
    field :fare_media_id, :string
    field :amount, :decimal
    field :currency, :string
    field :rider_category_id, :string
    field :bundle_amount, :integer
    field :duration_start, :integer
    field :duration_amount, :integer
    field :duration_unit, :integer

    belongs_to :organization, GtfsPlanner.Organizations.Organization,
      foreign_key: :organization_id

    field :gtfs_version_id, :binary_id

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          organization_id: Ecto.UUID.t(),
          gtfs_version_id: Ecto.UUID.t(),
          fare_product_id: String.t(),
          fare_product_name: String.t() | nil,
          fare_media_id: String.t() | nil,
          amount: Decimal.t(),
          currency: String.t(),
          rider_category_id: String.t() | nil,
          bundle_amount: integer() | nil,
          duration_start: integer() | nil,
          duration_amount: integer() | nil,
          duration_unit: integer() | nil,
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  @doc "Creates a changeset for a fare product."
  def changeset(fare_product, attrs) do
    fare_product
    |> cast(attrs, [
      :fare_product_id,
      :fare_product_name,
      :fare_media_id,
      :amount,
      :currency,
      :rider_category_id,
      :bundle_amount,
      :duration_start,
      :duration_amount,
      :duration_unit,
      :organization_id,
      :gtfs_version_id
    ])
    |> trim_string_fields()
    |> validate_required([
      :fare_product_id,
      :amount,
      :currency,
      :organization_id,
      :gtfs_version_id
    ])
    # The index is named explicitly because the key is longer than the 63
    # characters PostgreSQL allows for Ecto's generated constraint name.
    |> unique_constraint(
      [
        :organization_id,
        :gtfs_version_id,
        :fare_product_id,
        :rider_category_id,
        :fare_media_id
      ],
      name: "fare_products_org_version_product_rider_category_media_index"
    )
    |> foreign_key_constraint(:organization_id)
  end
end
