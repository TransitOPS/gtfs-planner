defmodule GtfsPlanner.Organizations.Organization do
  use Ecto.Schema
  import Ecto.Changeset
  import GtfsPlanner.ChangesetHelpers

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          alias: String.t(),
          name: String.t(),
          product: :planner | :pathways,
          active_gtfs_version_id: Ecto.UUID.t() | nil,
          active_gtfs_version_revision: non_neg_integer(),
          active_full_publication_sequence: non_neg_integer(),
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "organizations" do
    field :alias, :string
    field :name, :string
    field :product, Ecto.Enum, values: [:planner, :pathways], default: :planner

    # Server-owned active-schedule selection. `GtfsPlanner.Versions` is the only writer;
    # `changeset/2` never casts these, so no form or API attribute can reach them.
    field :active_gtfs_version_id, :binary_id
    field :active_gtfs_version_revision, :integer, default: 0
    field :active_full_publication_sequence, :integer, default: 0

    timestamps(type: :utc_datetime_usec)
  end

  @doc """
  A changeset for creating and updating organizations.

  ## Examples

      iex> changeset(organization, %{alias: "demo", name: "Demo Org"})
      %Ecto.Changeset{source: %Organization{}}

  """
  def changeset(organization, attrs) do
    organization
    |> cast(attrs, [:alias, :name, :product])
    |> trim_string_fields()
    |> normalize_alias()
    |> validate_required([:alias, :name, :product])
    |> validate_length(:alias, max: 255)
    |> validate_length(:name, max: 255)
    |> unique_constraint(:alias)
  end

  defp normalize_alias(changeset) do
    case get_change(changeset, :alias) do
      nil ->
        changeset

      value ->
        normalized =
          value
          |> String.trim()
          |> String.downcase()
          |> String.replace(~r/[^a-z0-9\s-]/, "")
          |> String.replace(~r/\s+/, "-")

        put_change(changeset, :alias, normalized)
    end
  end
end
