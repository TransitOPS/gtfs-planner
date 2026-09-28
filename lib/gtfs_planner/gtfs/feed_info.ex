defmodule GtfsPlanner.Gtfs.FeedInfo do
  use Ecto.Schema
  import Ecto.Changeset
  import GtfsPlanner.ChangesetHelpers

  alias GtfsPlanner.Gtfs.LanguageCodes

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @editor_fields [
    :feed_publisher_name,
    :feed_publisher_url,
    :feed_lang,
    :default_lang,
    :feed_start_date,
    :feed_end_date,
    :feed_version,
    :feed_contact_email,
    :feed_contact_url
  ]
  @editor_text_fields [
    :feed_publisher_name,
    :feed_publisher_url,
    :feed_lang,
    :default_lang,
    :feed_version,
    :feed_contact_email,
    :feed_contact_url
  ]
  @length_max 255
  @language_message "is not a supported language"
  @date_order_message "must be on or after the valid-from date"

  schema "feed_info" do
    field :feed_publisher_name, :string
    field :feed_publisher_url, :string
    field :feed_lang, :string
    field :default_lang, :string
    field :feed_start_date, :date
    field :feed_end_date, :date
    field :feed_version, :string
    field :feed_contact_email, :string
    field :feed_contact_url, :string

    belongs_to :organization, GtfsPlanner.Organizations.Organization,
      foreign_key: :organization_id

    field :gtfs_version_id, :binary_id

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          organization_id: Ecto.UUID.t(),
          gtfs_version_id: Ecto.UUID.t(),
          feed_publisher_name: String.t(),
          feed_publisher_url: String.t(),
          feed_lang: String.t(),
          default_lang: String.t() | nil,
          feed_start_date: Date.t() | nil,
          feed_end_date: Date.t() | nil,
          feed_version: String.t() | nil,
          feed_contact_email: String.t() | nil,
          feed_contact_url: String.t() | nil,
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  @doc "Creates a changeset for feed info."
  def changeset(feed_info, attrs) do
    feed_info
    |> cast(attrs, [
      :feed_publisher_name,
      :feed_publisher_url,
      :feed_lang,
      :default_lang,
      :feed_start_date,
      :feed_end_date,
      :feed_version,
      :feed_contact_email,
      :feed_contact_url,
      :organization_id,
      :gtfs_version_id
    ])
    |> trim_string_fields()
    |> validate_required([
      :feed_publisher_name,
      :feed_publisher_url,
      :feed_lang,
      :organization_id,
      :gtfs_version_id
    ])
    |> unique_constraint([:organization_id, :gtfs_version_id])
    |> foreign_key_constraint(:organization_id)
  end

  @doc """
  Creates a changeset for the feed details drawer (R9).

  Casts the editable fields only, so `organization_id` and `gtfs_version_id`
  keep the values already on the struct. Required fields, 255-codepoint text,
  http(s) URLs, emails and the date range are checked on changed fields, so an
  imported value outside those formats does not block an unrelated edit. The
  feed language accepts `mul`; the default language does not (R12).
  """
  def editor_changeset(feed_info, attrs) do
    feed_info
    |> cast(attrs, @editor_fields)
    |> trim_string_fields()
    |> validate_required([:feed_publisher_name, :feed_publisher_url, :feed_lang])
    |> validate_lengths()
    |> validate_http_url(:feed_publisher_url)
    |> validate_http_url(:feed_contact_url)
    |> validate_email_address(:feed_contact_email)
    |> validate_language(:feed_lang, include_mul: true)
    |> validate_language(:default_lang, [])
    |> validate_date_order()
    # The unique index covers the version's single feed_info row.
    |> unique_constraint([:organization_id, :gtfs_version_id],
      error_key: :feed_publisher_name
    )
  end

  defp validate_lengths(changeset) do
    Enum.reduce(
      @editor_text_fields,
      changeset,
      &validate_length(&2, &1, max: @length_max, count: :codepoints)
    )
  end

  defp validate_language(changeset, field, opts) do
    validate_change(changeset, field, fn _field, language ->
      if LanguageCodes.valid?(language, opts),
        do: [],
        else: [{field, @language_message}]
    end)
  end

  defp validate_date_order(changeset) do
    start_date = get_field(changeset, :feed_start_date)
    end_date = get_field(changeset, :feed_end_date)

    if date_changed?(changeset) and match?(%Date{}, start_date) and match?(%Date{}, end_date) and
         Date.compare(end_date, start_date) == :lt do
      add_error(changeset, :feed_end_date, @date_order_message)
    else
      changeset
    end
  end

  defp date_changed?(changeset) do
    Map.has_key?(changeset.changes, :feed_start_date) or
      Map.has_key?(changeset.changes, :feed_end_date)
  end
end
