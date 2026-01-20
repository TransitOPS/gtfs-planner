defmodule GtfsPlanner.Versions.GtfsVersion do
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          organization_id: Ecto.UUID.t(),
          name: String.t(),
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "gtfs_versions" do
    field :organization_id, Ecto.UUID
    field :name, :string

    timestamps(type: :utc_datetime_usec)
  end

  @doc """
  A changeset for creating and updating GTFS versions.

  ## Examples

      iex> changeset(gtfs_version, %{name: "Spring 2024"})
      %Ecto.Changeset{source: %GtfsVersion{}}

  """
  def changeset(gtfs_version, attrs) do
    gtfs_version
    |> cast(attrs, [:name])
    |> validate_required([:name])
    |> validate_length(:name, min: 1, max: 255)
  end
end
