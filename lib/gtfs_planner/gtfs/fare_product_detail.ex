defmodule GtfsPlanner.Gtfs.FareProductDetail do
  @moduledoc """
  The operator facts kept beside one stored `fare_products` row.

  The Fares v2 files do not record a product's kind, its order in the operator's
  price grid or which route groups accept a pass, so `Fares` stores them here and
  projects them back into the export. `kind` is `"single"`, `"pass"` or
  `"transfer_fee"`, and `accepted_network_ids` is the list of network IDs a pass
  is accepted on, where an empty list means none and the string `"all_routes"`
  stands for the rows with a nil network.

  `changeset/2` casts these four fields only. `organization_id` and
  `gtfs_version_id` are set on the struct by the writer and are never cast
  (AGENTS.md).
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @kinds ~w(single pass transfer_fee)

  schema "fare_product_details" do
    field :fare_product_id, :string
    field :kind, :string
    field :position, :integer, default: 0
    field :accepted_network_ids, {:array, :string}, default: []

    belongs_to :organization, GtfsPlanner.Organizations.Organization,
      foreign_key: :organization_id

    field :gtfs_version_id, :binary_id

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          organization_id: Ecto.UUID.t() | nil,
          gtfs_version_id: Ecto.UUID.t() | nil,
          fare_product_id: String.t() | nil,
          kind: String.t() | nil,
          position: integer | nil,
          accepted_network_ids: [String.t()] | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @doc "The values `kind` may hold."
  @spec kinds() :: [String.t()]
  def kinds, do: @kinds

  @doc """
  A changeset for one product's detail row.

  A product imported without a kind keeps a null `kind`, which the database
  check admits; the value is validated only when the writer sets one.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(detail, attrs) do
    detail
    |> cast(attrs, [:fare_product_id, :kind, :position, :accepted_network_ids])
    |> validate_inclusion(:kind, @kinds)
    |> unique_constraint([:organization_id, :gtfs_version_id, :fare_product_id],
      name: :fare_product_details_org_version_product_id_index
    )
    |> check_constraint(:kind, name: :kind_must_be_known)
  end
end
