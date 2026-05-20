defmodule GtfsPlanner.Gtfs.Transfer do
  use Ecto.Schema
  import Ecto.Changeset
  import GtfsPlanner.ChangesetHelpers

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "transfers" do
    field :from_stop_id, :string
    field :to_stop_id, :string
    field :from_route_id, :string
    field :to_route_id, :string
    field :from_trip_id, :string
    field :to_trip_id, :string
    field :transfer_type, :integer
    field :min_transfer_time, :integer

    belongs_to :organization, GtfsPlanner.Organizations.Organization,
      foreign_key: :organization_id

    field :gtfs_version_id, :binary_id

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          organization_id: Ecto.UUID.t(),
          gtfs_version_id: Ecto.UUID.t(),
          from_stop_id: String.t(),
          to_stop_id: String.t(),
          from_route_id: String.t() | nil,
          to_route_id: String.t() | nil,
          from_trip_id: String.t() | nil,
          to_trip_id: String.t() | nil,
          transfer_type: integer(),
          min_transfer_time: integer() | nil,
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  @doc "Creates a changeset for a transfer."
  def changeset(transfer, attrs) do
    transfer
    |> cast(attrs, [
      :from_stop_id,
      :to_stop_id,
      :from_route_id,
      :to_route_id,
      :from_trip_id,
      :to_trip_id,
      :transfer_type,
      :min_transfer_time,
      :organization_id,
      :gtfs_version_id
    ])
    |> trim_string_fields()
    |> validate_required([
      :from_stop_id,
      :to_stop_id,
      :transfer_type,
      :organization_id,
      :gtfs_version_id
    ])
    |> validate_inclusion(:transfer_type, 0..5)
    |> unique_constraint([
      :organization_id,
      :gtfs_version_id,
      :from_stop_id,
      :to_stop_id,
      :from_route_id,
      :to_route_id,
      :from_trip_id,
      :to_trip_id
    ])
    |> foreign_key_constraint(:organization_id)
  end
end
