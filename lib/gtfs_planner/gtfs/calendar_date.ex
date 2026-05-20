defmodule GtfsPlanner.Gtfs.CalendarDate do
  use Ecto.Schema
  import Ecto.Changeset
  import GtfsPlanner.ChangesetHelpers

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "calendar_dates" do
    field :service_id, :string
    field :date, :date
    field :exception_type, :integer

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
          date: Date.t(),
          exception_type: integer(),
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  @doc "Creates a changeset for a calendar date."
  def changeset(calendar_date, attrs) do
    calendar_date
    |> cast(attrs, [
      :service_id,
      :date,
      :exception_type,
      :organization_id,
      :gtfs_version_id
    ])
    |> trim_string_fields()
    |> validate_required([
      :service_id,
      :date,
      :exception_type,
      :organization_id,
      :gtfs_version_id
    ])
    |> validate_inclusion(:exception_type, 1..2)
    |> unique_constraint([:organization_id, :gtfs_version_id, :service_id, :date])
    |> foreign_key_constraint(:organization_id)
  end

  @doc "Returns human-readable label for exception_type."
  def exception_type_label(exception_type) do
    case exception_type do
      1 -> "Service added"
      2 -> "Service removed"
      _ -> "Unknown"
    end
  end
end
