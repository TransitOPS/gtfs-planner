defmodule GtfsPlanner.Gtfs.CalendarAttribute do
  @moduledoc """
  Schema for GTFS calendar attributes (MBTA extension).

  Stores human-readable schedule names, descriptions, schedule classifications,
  typicality, and seasonal rating metadata for a service ID.
  """
  use Ecto.Schema
  import Ecto.Changeset
  import GtfsPlanner.ChangesetHelpers

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @service_schedule_types ~w(Weekday Weekend Saturday Sunday Other)

  schema "calendar_attributes" do
    field :service_id, :string
    field :service_description, :string
    field :service_schedule_name, :string
    field :service_schedule_type, :string
    field :service_schedule_typicality, :integer, default: 0
    field :rating_start_date, :date
    field :rating_end_date, :date
    field :rating_description, :string

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
          service_description: String.t() | nil,
          service_schedule_name: String.t() | nil,
          service_schedule_type: String.t() | nil,
          service_schedule_typicality: integer(),
          rating_start_date: Date.t() | nil,
          rating_end_date: Date.t() | nil,
          rating_description: String.t() | nil,
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  @doc "Returns the list of supported service_schedule_type values."
  def service_schedule_types, do: @service_schedule_types

  @doc "Changeset for calendar attributes."
  def changeset(calendar_attribute, attrs) do
    calendar_attribute
    |> cast(attrs, [
      :service_id,
      :service_description,
      :service_schedule_name,
      :service_schedule_type,
      :service_schedule_typicality,
      :rating_start_date,
      :rating_end_date,
      :rating_description,
      :organization_id,
      :gtfs_version_id
    ])
    |> trim_string_fields()
    |> validate_required([
      :service_id,
      :organization_id,
      :gtfs_version_id
    ])
    |> validate_inclusion(:service_schedule_type, @service_schedule_types)
    |> validate_inclusion(:service_schedule_typicality, 0..6)
    |> validate_rating_dates()
    |> unique_constraint([:organization_id, :gtfs_version_id, :service_id],
      name: :calendar_attributes_organization_id_gtfs_version_id_service_id_
    )
    |> foreign_key_constraint(:organization_id)
  end

  defp validate_rating_dates(changeset) do
    start_date = get_field(changeset, :rating_start_date)
    end_date = get_field(changeset, :rating_end_date)

    if start_date && end_date && Date.compare(end_date, start_date) == :lt do
      add_error(changeset, :rating_end_date, "must be greater than or equal to rating_start_date")
    else
      changeset
    end
  end
end
