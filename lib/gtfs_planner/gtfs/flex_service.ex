defmodule GtfsPlanner.Gtfs.FlexService do
  @moduledoc """
  An authored on-demand (flex) service, scoped to one organization and version.

  A service is either an `:area` service, whose riders travel between drawn
  areas and connecting stops, or a `:detour` service on a fixed route. Its hours
  and booking rules are embedded rows, so one `lock_version` covers the whole
  service page's Save (R6, R7).

  `key` is the stable identifier R11 generates at creation from the name; it is
  cast only by `create_changeset/2` and never by `changeset/2`, so a rename
  keeps it. `organization_id` and `gtfs_version_id` are set on the struct by
  callers and are never cast.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias GtfsPlanner.ChangesetHelpers
  alias GtfsPlanner.Gtfs.FlexArea
  alias GtfsPlanner.Gtfs.FlexBookingRule
  alias GtfsPlanner.Gtfs.FlexHours

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @kinds [:area, :detour]
  @riders [:anyone, :registered]
  @measures [:route, :stops]
  @dropoffs [:tell_driver, :book, :dropoff_only]

  @time_format ~r/\A([01]\d|2[0-3]):[0-5]\d\z/
  @time_message "Enter a time as HH:MM, between 00:00 and 23:59."
  @phone_format ~r/\A\(?\d{3}\)?[\s.-]?\d{3}[\s.-]?\d{4}\z/
  @phone_message "Enter the phone number as 10 digits, for example (541) 555-0142."
  @booking_url_format ~r/\Ahttps:\/\/[^\s.]+\.[^\s]+\z/
  @booking_url_message "Enter the full booking link, starting with https://"
  @key_in_use_message "That key is already used in this version. Choose another name."

  @cast_fields [
    :name,
    :kind,
    :active,
    :agency_id,
    :riders,
    :eligibility,
    :include_registered,
    :phone,
    :phone_hours,
    :booking_url,
    :info_url,
    :note,
    :hub_stop_ids,
    :route_id,
    :distance_m,
    :wording,
    :measure,
    :first_stop_id,
    :last_stop_id,
    :dropoffs,
    :ada_only,
    :band_start,
    :band_end,
    :calendar_service_ids
  ]

  schema "flex_services" do
    field :key, :string
    field :name, :string
    field :kind, Ecto.Enum, values: @kinds
    field :active, :boolean, default: true
    field :agency_id, :string
    field :riders, Ecto.Enum, values: @riders, default: :anyone
    field :eligibility, :string
    field :include_registered, :boolean, default: false
    field :phone, :string
    field :phone_hours, :map
    field :booking_url, :string
    field :info_url, :string
    field :note, :string
    embeds_many :hours, FlexHours, on_replace: :delete
    embeds_many :booking_rules, FlexBookingRule, on_replace: :delete
    field :hub_stop_ids, {:array, :string}, default: []
    field :route_id, :string
    field :distance_m, :integer
    field :wording, :string
    field :measure, Ecto.Enum, values: @measures, default: :route
    field :first_stop_id, :string
    field :last_stop_id, :string
    field :dropoffs, Ecto.Enum, values: @dropoffs, default: :tell_driver
    field :ada_only, :boolean, default: false
    field :band_start, :string
    field :band_end, :string
    field :calendar_service_ids, {:array, :string}, default: []
    field :lock_version, :integer, default: 1

    belongs_to :organization, GtfsPlanner.Organizations.Organization
    field :gtfs_version_id, :binary_id

    has_many :areas, FlexArea, preload_order: [asc: :position]

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          organization_id: Ecto.UUID.t() | nil,
          gtfs_version_id: Ecto.UUID.t() | nil,
          key: String.t() | nil,
          name: String.t() | nil,
          kind: :area | :detour | nil,
          active: boolean(),
          agency_id: String.t() | nil,
          riders: :anyone | :registered,
          eligibility: String.t() | nil,
          include_registered: boolean(),
          phone: String.t() | nil,
          phone_hours: map() | nil,
          booking_url: String.t() | nil,
          info_url: String.t() | nil,
          note: String.t() | nil,
          hours: [FlexHours.t()],
          booking_rules: [FlexBookingRule.t()],
          hub_stop_ids: [String.t()],
          route_id: String.t() | nil,
          distance_m: integer() | nil,
          wording: String.t() | nil,
          measure: :route | :stops,
          first_stop_id: String.t() | nil,
          last_stop_id: String.t() | nil,
          dropoffs: :tell_driver | :book | :dropoff_only,
          ada_only: boolean(),
          band_start: String.t() | nil,
          band_end: String.t() | nil,
          calendar_service_ids: [String.t()],
          lock_version: integer(),
          areas: [FlexArea.t()] | Ecto.Association.NotLoaded.t(),
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @doc """
  Creates a changeset for a new service.

  Casts the R11 `key` (already derived by `GtfsPlanner.Gtfs.Flex`) as well as
  the user-editable fields, and requires a name and kind, plus a route for a
  detour.
  """
  @spec create_changeset(t(), map()) :: Ecto.Changeset.t()
  def create_changeset(service, attrs) do
    service
    |> cast(attrs, [:key | @cast_fields])
    |> validate_service()
    |> validate_required([:key])
  end

  @doc """
  Creates a changeset for an existing service.

  Never casts `key`, so a rename keeps the stored identifier. Locks
  `lock_version`, so a Save built from a stale struct raises
  `Ecto.StaleEntryError` instead of overwriting another editor's changes.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(service, attrs) do
    service
    |> cast(attrs, @cast_fields)
    |> validate_service()
    |> optimistic_lock(:lock_version)
  end

  defp validate_service(changeset) do
    changeset
    |> ChangesetHelpers.trim_string_fields()
    |> cast_embed(:hours, with: &FlexHours.changeset/2)
    |> cast_embed(:booking_rules, with: &FlexBookingRule.changeset/2)
    |> validate_required([:name, :kind])
    |> require_route_for_detour()
    |> validate_format(:phone, @phone_format, message: @phone_message)
    |> validate_format(:booking_url, @booking_url_format, message: @booking_url_message)
    |> validate_format(:band_start, @time_format, message: @time_message)
    |> validate_format(:band_end, @time_format, message: @time_message)
    |> validate_number(:distance_m, greater_than: 0)
    |> unique_constraint([:organization_id, :gtfs_version_id, :key],
      error_key: :key,
      message: @key_in_use_message
    )
  end

  defp require_route_for_detour(changeset) do
    if get_field(changeset, :kind) == :detour do
      validate_required(changeset, [:route_id])
    else
      changeset
    end
  end
end
