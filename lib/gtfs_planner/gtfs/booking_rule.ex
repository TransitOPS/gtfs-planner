defmodule GtfsPlanner.Gtfs.BookingRule do
  use Ecto.Schema
  import Ecto.Changeset
  import GtfsPlanner.ChangesetHelpers

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "booking_rules" do
    field :booking_rule_id, :string
    field :booking_type, :integer
    field :prior_notice_duration_min, :integer
    field :prior_notice_duration_max, :integer
    field :prior_notice_last_day, :integer
    field :prior_notice_last_time, :string
    field :prior_notice_start_day, :integer
    field :prior_notice_start_time, :string
    field :prior_notice_service_id, :string
    field :message, :string
    field :pickup_message, :string
    field :drop_off_message, :string
    field :phone_number, :string
    field :info_url, :string
    field :booking_url, :string

    belongs_to :organization, GtfsPlanner.Organizations.Organization,
      foreign_key: :organization_id

    field :gtfs_version_id, :binary_id

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          organization_id: Ecto.UUID.t(),
          gtfs_version_id: Ecto.UUID.t(),
          booking_rule_id: String.t(),
          booking_type: integer(),
          prior_notice_duration_min: integer() | nil,
          prior_notice_duration_max: integer() | nil,
          prior_notice_last_day: integer() | nil,
          prior_notice_last_time: String.t() | nil,
          prior_notice_start_day: integer() | nil,
          prior_notice_start_time: String.t() | nil,
          prior_notice_service_id: String.t() | nil,
          message: String.t() | nil,
          pickup_message: String.t() | nil,
          drop_off_message: String.t() | nil,
          phone_number: String.t() | nil,
          info_url: String.t() | nil,
          booking_url: String.t() | nil,
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  @doc "Creates a changeset for a booking rule."
  def changeset(booking_rule, attrs) do
    booking_rule
    |> cast(attrs, [
      :booking_rule_id,
      :booking_type,
      :prior_notice_duration_min,
      :prior_notice_duration_max,
      :prior_notice_last_day,
      :prior_notice_last_time,
      :prior_notice_start_day,
      :prior_notice_start_time,
      :prior_notice_service_id,
      :message,
      :pickup_message,
      :drop_off_message,
      :phone_number,
      :info_url,
      :booking_url,
      :organization_id,
      :gtfs_version_id
    ])
    |> trim_string_fields()
    |> validate_required([:booking_rule_id, :booking_type, :organization_id, :gtfs_version_id])
    |> unique_constraint([:organization_id, :gtfs_version_id, :booking_rule_id])
    |> foreign_key_constraint(:organization_id)
  end
end
