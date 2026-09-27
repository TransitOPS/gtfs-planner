defmodule GtfsPlanner.Gtfs.Calendar do
  use Ecto.Schema
  import Ecto.Changeset
  import GtfsPlanner.ChangesetHelpers

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
    |> trim_string_fields()
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

  @weekday_fields [:monday, :tuesday, :wednesday, :thursday, :friday, :saturday, :sunday]

  @doc """
  Creates a changeset for an interactively created or changed weekly definition.

  Import acceptance stays permissive: an imported weekly row may carry all-zero
  weekday columns and `changeset/2` remains the import path. Editor input must name at
  least one service day and put the end date on or after the start date, so both rules
  are added here instead of tightening the shared changeset.
  """
  def editor_changeset(calendar, attrs) do
    calendar
    |> changeset(attrs)
    |> validate_service_days()
    |> validate_ordered_dates()
  end

  defp validate_service_days(changeset) do
    if Enum.any?(@weekday_fields, fn field -> get_field(changeset, field) == 1 end) do
      changeset
    else
      add_error(changeset, :service_days, "select at least one service day")
    end
  end

  defp validate_ordered_dates(%{valid?: false} = changeset), do: changeset

  defp validate_ordered_dates(changeset) do
    if Date.compare(get_field(changeset, :end_date), get_field(changeset, :start_date)) == :lt do
      add_error(changeset, :end_date, "must be on or after the start date")
    else
      changeset
    end
  end
end
