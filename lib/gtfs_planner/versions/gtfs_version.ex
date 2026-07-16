defmodule GtfsPlanner.Versions.GtfsVersion do
  use Ecto.Schema
  import Ecto.Changeset
  import GtfsPlanner.ChangesetHelpers

  alias GtfsPlanner.Repo

  @publication_statuses ~w(staging importing published failed)

  @status_check_constraint "gtfs_versions_publication_status_check"
  @state_timestamp_check_constraint "gtfs_versions_publication_state_timestamp_check"

  @type publication_status :: String.t()

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          organization_id: Ecto.UUID.t(),
          name: String.t(),
          publication_status: publication_status(),
          published_at: DateTime.t() | nil,
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "gtfs_versions" do
    field :organization_id, Ecto.UUID
    field :name, :string
    field :publication_status, :string, default: "published"
    field :published_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec)
  end

  @doc """
  Returns the allowed publication lifecycle states.
  """
  @spec publication_statuses() :: [publication_status()]
  def publication_statuses, do: @publication_statuses

  @doc """
  A user-facing changeset that only casts and validates the version name.

  Lifecycle fields (`publication_status`/`published_at`) are never cast from
  user parameters; they are system-owned and set explicitly by the create and
  transition changesets below.

  ## Examples

      iex> name_changeset(gtfs_version, %{name: "Spring 2024"})
      %Ecto.Changeset{}
  """
  @spec name_changeset(t() | Ecto.Changeset.t(), map()) :: Ecto.Changeset.t()
  def name_changeset(gtfs_version, attrs) do
    gtfs_version
    |> cast(attrs, [:name])
    |> trim_string_fields()
    |> validate_required([:name])
    |> validate_length(:name, min: 1, max: 255)
    |> unsafe_validate_unique([:name, :organization_id], Repo,
      message: "A version with this name already exists"
    )
    |> unique_constraint(:name,
      name: :gtfs_versions_organization_id_name_index,
      message: "A version with this name already exists"
    )
  end

  @doc """
  Backwards-compatible alias for `name_changeset/2`.
  """
  @spec changeset(t() | Ecto.Changeset.t(), map()) :: Ecto.Changeset.t()
  def changeset(gtfs_version, attrs), do: name_changeset(gtfs_version, attrs)

  @doc """
  A changeset for creating an immediately-published version.

  The version name is taken from user attributes, but the lifecycle pair is
  system-owned: `publication_status` is forced to `"published"` and
  `published_at` is set to the supplied system time (defaulting to now).
  """
  @spec published_create_changeset(t() | Ecto.Changeset.t(), map(), DateTime.t()) ::
          Ecto.Changeset.t()
  def published_create_changeset(gtfs_version, attrs, published_at \\ DateTime.utc_now()) do
    gtfs_version
    |> name_changeset(attrs)
    |> put_lifecycle("published", published_at)
    |> validate_lifecycle()
  end

  @doc """
  A changeset for creating a `"staging"` version.

  The name is taken from user attributes; `publication_status` is forced to
  `"staging"` and `published_at` is forced to an explicit `nil`.
  """
  @spec staging_create_changeset(t() | Ecto.Changeset.t(), map()) :: Ecto.Changeset.t()
  def staging_create_changeset(gtfs_version, attrs) do
    gtfs_version
    |> name_changeset(attrs)
    |> put_lifecycle("staging", nil)
    |> validate_lifecycle()
  end

  @doc """
  A system-owned lifecycle transition changeset.

  `status` and `published_at` are set directly from system-provided values and
  are never cast from user parameters. Callers pass the new status and, for a
  publication, the system/database time. Every other state forces
  `published_at` to `nil`.
  """
  @spec transition_changeset(t() | Ecto.Changeset.t(), publication_status(), DateTime.t() | nil) ::
          Ecto.Changeset.t()
  def transition_changeset(gtfs_version, status, published_at \\ nil) do
    published_at = if status == "published", do: published_at, else: nil

    gtfs_version
    |> put_lifecycle(status, published_at)
    |> validate_lifecycle()
  end

  defp put_lifecycle(changeset, status, published_at) do
    changeset
    |> change()
    |> put_change(:publication_status, status)
    |> put_change(:published_at, published_at)
  end

  defp validate_lifecycle(changeset) do
    changeset
    |> validate_required([:publication_status])
    |> validate_inclusion(:publication_status, @publication_statuses)
    |> validate_paired_timestamp()
    |> check_constraint(:publication_status,
      name: @status_check_constraint,
      message: "is not a valid publication status"
    )
    |> check_constraint(:published_at,
      name: @state_timestamp_check_constraint,
      message: "must be set only for published versions"
    )
  end

  defp validate_paired_timestamp(changeset) do
    status = get_field(changeset, :publication_status)
    published_at = get_field(changeset, :published_at)

    cond do
      status == "published" and is_nil(published_at) ->
        add_error(changeset, :published_at, "must be set when the version is published")

      status != "published" and not is_nil(published_at) ->
        add_error(changeset, :published_at, "must be nil unless the version is published")

      true ->
        changeset
    end
  end
end
