defmodule GtfsPlanner.Gtfs.FareVersionSetting do
  @moduledoc """
  The storage-only marker of a version whose fares are managed here.

  A version becomes managed when `Fares.Conversion` inserts this row with
  `managed_at` set; the export and the fare editors read it through
  `GtfsPlanner.Gtfs.Fares.managed?/2` and `settings/2` rather than querying the
  table themselves. `older_format` records whether the Fares v1 files are derived
  from the stored v2 rows or streamed from the rows an earlier v1 import stored,
  and `conversion_operation_id` names the change-log entry a conversion wrote so
  undo can find it again.

  `changeset/2` casts `older_format` and `conversion_operation_id` only.
  `managed_at`, `organization_id` and `gtfs_version_id` are set on the struct by
  the writer and are never cast, so a request can neither mark a version managed
  nor write another organization's row (AGENTS.md).
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @older_formats ~w(derived imported)

  schema "fare_version_settings" do
    field :managed_at, :utc_datetime_usec
    field :older_format, :string, default: "derived"
    field :conversion_operation_id, :binary_id

    belongs_to :organization, GtfsPlanner.Organizations.Organization,
      foreign_key: :organization_id

    field :gtfs_version_id, :binary_id

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          organization_id: Ecto.UUID.t() | nil,
          gtfs_version_id: Ecto.UUID.t() | nil,
          managed_at: DateTime.t() | nil,
          older_format: String.t() | nil,
          conversion_operation_id: Ecto.UUID.t() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @doc "The values `older_format` may hold, in export order."
  @spec older_formats() :: [String.t()]
  def older_formats, do: @older_formats

  @doc """
  A changeset for the editable fields of a version's settings row.

  `managed_at` is never cast: it is written by `Fares.Conversion` on the struct,
  so this changeset can neither create nor un-manage a version.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(setting, attrs) do
    setting
    |> cast(attrs, [:older_format, :conversion_operation_id])
    |> validate_inclusion(:older_format, @older_formats)
    |> unique_constraint([:organization_id, :gtfs_version_id],
      name: :fare_version_settings_organization_id_gtfs_version_id_index
    )
    |> check_constraint(:older_format, name: :older_format_must_be_known)
  end
end
