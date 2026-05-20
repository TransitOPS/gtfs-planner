defmodule GtfsPlanner.Gtfs.FareLegRule do
  use Ecto.Schema
  import Ecto.Changeset
  import GtfsPlanner.ChangesetHelpers

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "fare_leg_rules" do
    field :leg_group_id, :string
    field :network_id, :string
    field :from_area_id, :string
    field :to_area_id, :string
    field :from_timeframe_group_id, :string
    field :to_timeframe_group_id, :string
    field :fare_product_id, :string
    field :rule_priority, :integer

    belongs_to :organization, GtfsPlanner.Organizations.Organization,
      foreign_key: :organization_id

    field :gtfs_version_id, :binary_id

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          organization_id: Ecto.UUID.t(),
          gtfs_version_id: Ecto.UUID.t(),
          leg_group_id: String.t() | nil,
          network_id: String.t() | nil,
          from_area_id: String.t() | nil,
          to_area_id: String.t() | nil,
          from_timeframe_group_id: String.t() | nil,
          to_timeframe_group_id: String.t() | nil,
          fare_product_id: String.t() | nil,
          rule_priority: integer() | nil,
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  @doc "Creates a changeset for a fare leg rule."
  def changeset(fare_leg_rule, attrs) do
    fare_leg_rule
    |> cast(attrs, [
      :leg_group_id,
      :network_id,
      :from_area_id,
      :to_area_id,
      :from_timeframe_group_id,
      :to_timeframe_group_id,
      :fare_product_id,
      :rule_priority,
      :organization_id,
      :gtfs_version_id
    ])
    |> trim_string_fields()
    |> validate_required([:organization_id, :gtfs_version_id])
    |> unique_constraint([
      :organization_id,
      :gtfs_version_id,
      :network_id,
      :from_area_id,
      :to_area_id,
      :fare_product_id
    ])
    |> foreign_key_constraint(:organization_id)
  end
end
