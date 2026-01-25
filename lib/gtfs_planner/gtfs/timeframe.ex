defmodule GtfsPlanner.Gtfs.Timeframe do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "timeframes" do
    field :timeframe_group_id, :string
    field :start_time, :string
    field :end_time, :string
    field :service_id, :string

    belongs_to :organization, GtfsPlanner.Organizations.Organization,
      foreign_key: :organization_id

    field :gtfs_version_id, :binary_id

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          organization_id: Ecto.UUID.t(),
          gtfs_version_id: Ecto.UUID.t(),
          timeframe_group_id: String.t(),
          start_time: String.t() | nil,
          end_time: String.t() | nil,
          service_id: String.t(),
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  @doc "Creates a changeset for a timeframe."
  def changeset(timeframe, attrs) do
    timeframe
    |> cast(attrs, [
      :timeframe_group_id,
      :start_time,
      :end_time,
      :service_id,
      :organization_id,
      :gtfs_version_id
    ])
    |> validate_required([:timeframe_group_id, :service_id, :organization_id, :gtfs_version_id])
    |> unique_constraint([:organization_id, :gtfs_version_id, :timeframe_group_id, :start_time, :end_time, :service_id])
    |> foreign_key_constraint(:organization_id)
  end
end