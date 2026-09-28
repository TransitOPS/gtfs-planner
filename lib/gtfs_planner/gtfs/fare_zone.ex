defmodule GtfsPlanner.Gtfs.FareZone do
  @moduledoc """
  Version-scoped metadata for a fare zone.

  A zone's identity is its `zone_id` string, unique inside one organization and
  GTFS version and compared byte-for-byte. The record carries only metadata (a
  display name and a map color); stop membership lives on `stops.zone_id`.
  `changeset/3` therefore has two modes: `:new` validates and trims an ID the
  user has entered, and `:keep` edits the metadata of the exact stored ID and
  never casts `zone_id`, so an imported ID such as `" A"` or `"Zone 1"` keeps
  its bytes through a rename. `organization_id` and `gtfs_version_id` are set on
  the struct by callers and are never cast.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @palette [
    {"ocean", "Ocean blue", "#1f5fbf"},
    {"teal", "Teal", "#0d737d"},
    {"plum", "Plum", "#4b1f78"},
    {"ochre", "Ochre", "#8a5a0e"},
    {"green", "Green", "#267548"}
  ]

  @palette_keys Enum.map(@palette, fn {key, _label, _hex} -> key end)
  @palette_by_key Map.new(@palette, fn {key, _label, hex} -> {key, hex} end)

  @zone_id_format ~r/\A[A-Za-z0-9_-]{1,64}\z/
  @zone_id_in_use_message "That zone ID is already in use. Choose another."

  schema "fare_zones" do
    field :zone_id, :string
    field :name, :string
    field :color, :string

    belongs_to :organization, GtfsPlanner.Organizations.Organization,
      foreign_key: :organization_id

    field :gtfs_version_id, :binary_id

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          organization_id: Ecto.UUID.t() | nil,
          gtfs_version_id: Ecto.UUID.t() | nil,
          zone_id: String.t() | nil,
          name: String.t() | nil,
          color: String.t() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @doc "The zone color palette as `{key, label, hex}` triples."
  @spec palette() :: [{String.t(), String.t(), String.t()}]
  def palette, do: @palette

  @doc "The prototype hex value of a palette key."
  @spec color_hex(String.t()) :: String.t()
  def color_hex(key), do: Map.fetch!(@palette_by_key, key)

  @doc """
  The `zone_id` field error shown when an ID is already in use.

  `GtfsPlanner.Gtfs.FareZones` uses it when an ID is carried by a stop or a fare
  rule rather than a `fare_zones` record, which the unique index cannot reject.
  """
  @spec zone_id_in_use_message() :: String.t()
  def zone_id_in_use_message, do: @zone_id_in_use_message

  @doc """
  A deterministic palette key for a zone that has no metadata record.

  The same ID always yields the same key, so an undeclared zone keeps one color
  across reads without storing anything.
  """
  @spec default_color(String.t()) :: String.t()
  def default_color(zone_id) do
    Enum.at(@palette_keys, :erlang.phash2(zone_id, length(@palette_keys)))
  end

  @doc """
  A changeset for zone metadata.

  `:new` is for an ID the user entered or changed: it casts `zone_id`, trims it
  and requires 1–64 letters, numbers, hyphens or underscores. `:keep` is for
  everything else, including a rename of an imported zone: it never casts
  `zone_id`, so the struct's exact bytes reach the database unchanged. Both
  modes trim and require a name of at most 60 characters and a palette color.
  """
  @spec changeset(t(), map(), :new | :keep) :: Ecto.Changeset.t()
  def changeset(zone, attrs, :new) do
    zone
    |> cast(attrs, [:zone_id, :name, :color])
    |> update_change(:zone_id, &trim/1)
    |> update_change(:name, &trim/1)
    |> validate_format(:zone_id, @zone_id_format,
      message: "Use 1–64 letters, numbers, hyphens or underscores."
    )
    |> validate_metadata()
  end

  def changeset(zone, attrs, :keep) do
    zone
    |> cast(attrs, [:name, :color])
    |> update_change(:name, &trim/1)
    |> validate_metadata()
  end

  defp validate_metadata(changeset) do
    changeset
    |> validate_required([:zone_id, :name, :color])
    |> validate_length(:name, max: 60)
    |> validate_inclusion(:color, @palette_keys)
    |> unique_constraint([:organization_id, :gtfs_version_id, :zone_id],
      name: :fare_zones_organization_id_gtfs_version_id_zone_id_index,
      message: @zone_id_in_use_message
    )
  end

  defp trim(value) when is_binary(value), do: String.trim(value)
  defp trim(value), do: value
end
