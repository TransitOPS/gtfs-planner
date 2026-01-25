defmodule GtfsPlanner.Gtfs.Frequency do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "frequencies" do
    field :trip_id, :string
    field :start_time, :string
    field :end_time, :string
    field :headway_secs, :integer
    field :exact_times, :integer

    belongs_to :organization, GtfsPlanner.Organizations.Organization,
      foreign_key: :organization_id

    field :gtfs_version_id, :binary_id

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          organization_id: Ecto.UUID.t(),
          gtfs_version_id: Ecto.UUID.t(),
          trip_id: String.t(),
          start_time: String.t(),
          end_time: String.t(),
          headway_secs: integer(),
          exact_times: integer() | nil,
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  @doc "Creates a changeset for a frequency."
  def changeset(frequency, attrs) do
    frequency
    |> cast(attrs, [
      :trip_id,
      :start_time,
      :end_time,
      :headway_secs,
      :exact_times,
      :organization_id,
      :gtfs_version_id
    ])
    |> validate_required([:trip_id, :start_time, :end_time, :headway_secs, :organization_id, :gtfs_version_id])
    |> validate_number(:headway_secs, greater_than: 0)
    |> validate_inclusion(:exact_times, 0..1)
    |> unique_constraint([:organization_id, :gtfs_version_id, :trip_id, :start_time])
    |> foreign_key_constraint(:organization_id)
  end
end