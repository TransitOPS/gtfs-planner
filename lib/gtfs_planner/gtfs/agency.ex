defmodule GtfsPlanner.Gtfs.Agency do
  use Ecto.Schema
  import Ecto.Changeset
  import GtfsPlanner.ChangesetHelpers

  alias GtfsPlanner.Gtfs.DisplayClock
  alias GtfsPlanner.Gtfs.LanguageCodes

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @editor_fields [
    :agency_name,
    :agency_url,
    :agency_timezone,
    :agency_lang,
    :agency_phone,
    :agency_fare_url,
    :agency_email
  ]
  @length_max 255
  @timezone_message "must be a valid timezone, such as America/New_York"
  @language_message "is not a supported language"

  schema "agencies" do
    field :agency_id, :string
    field :agency_name, :string
    field :agency_url, :string
    field :agency_timezone, :string
    field :agency_lang, :string
    field :agency_phone, :string
    field :agency_fare_url, :string
    field :agency_email, :string

    belongs_to :organization, GtfsPlanner.Organizations.Organization,
      foreign_key: :organization_id

    field :gtfs_version_id, :binary_id

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          organization_id: Ecto.UUID.t(),
          gtfs_version_id: Ecto.UUID.t(),
          agency_id: String.t() | nil,
          agency_name: String.t(),
          agency_url: String.t(),
          agency_timezone: String.t(),
          agency_lang: String.t() | nil,
          agency_phone: String.t() | nil,
          agency_fare_url: String.t() | nil,
          agency_email: String.t() | nil,
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  @doc "Creates a changeset for an agency."
  def changeset(agency, attrs) do
    agency
    |> cast(attrs, [
      :agency_id,
      :agency_name,
      :agency_url,
      :agency_timezone,
      :agency_lang,
      :agency_phone,
      :agency_fare_url,
      :agency_email,
      :organization_id,
      :gtfs_version_id
    ])
    |> trim_string_fields()
    |> validate_required([
      :agency_name,
      :agency_url,
      :agency_timezone,
      :organization_id,
      :gtfs_version_id
    ])
    |> unique_constraint([:organization_id, :gtfs_version_id, :agency_id])
    |> foreign_key_constraint(:organization_id)
  end

  @doc """
  Creates a changeset for the agency edit drawer (R9).

  Casts the editable fields only, so `organization_id`, `gtfs_version_id` and
  `agency_id` keep the values already on the struct. The URL, email and language
  checks run on changed fields, so an imported value outside those formats — an
  unresolved zone, `www.example.com`, `en-US` or `mul` — does not block an
  unrelated edit. `DisplayClock.valid_zone?/1` accepts exactly the zones the
  version clock resolves.
  """
  def editor_changeset(agency, attrs) do
    agency
    |> cast(attrs, @editor_fields)
    |> trim_string_fields()
    |> validate_required([:agency_name, :agency_url, :agency_timezone])
    |> validate_lengths()
    |> validate_http_url(:agency_url)
    |> validate_http_url(:agency_fare_url)
    |> validate_email_address(:agency_email)
    |> validate_change(:agency_timezone, fn :agency_timezone, timezone ->
      if DisplayClock.valid_zone?(timezone),
        do: [],
        else: [agency_timezone: @timezone_message]
    end)
    |> validate_change(:agency_lang, fn :agency_lang, language ->
      if LanguageCodes.valid?(language, []),
        do: [],
        else: [agency_lang: @language_message]
    end)
    # The unique index binds to :agency_id, which the drawer shows read-only.
    |> unique_constraint([:organization_id, :gtfs_version_id, :agency_id],
      error_key: :agency_name
    )
  end

  defp validate_lengths(changeset) do
    Enum.reduce(
      @editor_fields,
      changeset,
      &validate_length(&2, &1, max: @length_max, count: :codepoints)
    )
  end
end
