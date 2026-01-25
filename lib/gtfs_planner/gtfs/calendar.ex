defmodule GtfsPlanner.Gtfs.Calendar do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "calendars" do
    field :service_id, :string
    field :monday, :integer
    field :tuesday, :integer
    field :wednesday, :integer
    field :thursday, :integer
    field :friday, :integer
    field :saturday, :integer
    field :sunday, :integer
    field :start_date, :date
    field :end_date, :date

    belongs_to :organization, GtfsPlanner.Organizations.Organization,
      foreign_key: :organization_id

    belongs_to :gtfs_version, GtfsPlanner.Versions.GtfsVersion

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          organization_id: Ecto.UUID.t(),
          gtfs_version_id: Ecto.UUID.t(),
          service_id: String.t(),
          monday: integer(),
          tuesday: integer(),
          wednesday: integer(),
          thursday: integer(),
          friday: integer(),
          saturday: integer(),
          sunday: integer(),
          start_date: Date.t(),
          end_date: Date.t(),
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  @doc "Creates a changeset for a calendar."
  def changeset(calendar, attrs) do
    calendar
    |> cast(attrs, [
      :service_id,
      :monday,
      :tuesday,
      :wednesday,
      :thursday,
      :friday,
      :saturday,
      :sunday,
      :start_date,
      :end_date,
      :organization_id,
      :gtfs_version_id
    ])
    |> validate_required([
      :service_id,
      :monday,
      :tuesday,
      :wednesday,
      :thursday,
      :friday,
      :saturday,
      :sunday,
      :start_date,
      :end_date,
      :organization_id,
      :gtfs_version_id
    ])
    |> validate_inclusion(:monday, 0..1)
    |> validate_inclusion(:tuesday, 0..1)
    |> validate_inclusion(:wednesday, 0..1)
    |> validate_inclusion(:thursday, 0..1)
    |> validate_inclusion(:friday, 0..1)
    |> validate_inclusion(:saturday, 0..1)
    |> validate_inclusion(:sunday, 0..1)
    |> unique_constraint([:organization_id, :gtfs_version_id, :service_id])
    |> foreign_key_constraint(:organization_id)
  end
end