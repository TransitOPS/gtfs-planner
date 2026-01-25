defmodule GtfsPlanner.Gtfs.FeedInfo do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

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
    |> validate_required([:feed_publisher_name, :feed_publisher_url, :feed_lang, :organization_id, :gtfs_version_id])
    |> unique_constraint([:organization_id, :gtfs_version_id])
    |> foreign_key_constraint(:organization_id)
  end
end