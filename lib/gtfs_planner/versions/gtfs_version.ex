defmodule GtfsPlanner.Versions.GtfsVersion do
  use Ecto.Schema
  import Ecto.Changeset

  alias GtfsPlanner.Repo

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

  @spec changeset(
          {map(),
           %{
             optional(atom()) =>
               atom()
               | {:array | :assoc | :embed | :in | :map | :parameterized | :supertype | :try,
                  any()}
           }}
          | %{
              :__struct__ => atom() | %{:__changeset__ => any(), optional(any()) => any()},
              optional(atom()) => any()
            },
          :invalid | %{optional(:__struct__) => none(), optional(atom() | binary()) => any()}
        ) :: Ecto.Changeset.t()
  @doc """
  A changeset for creating and updating GTFS versions.

  ## Examples

      iex> changeset(gtfs_version, %{name: "Spring 2024"})
      %Ecto.Changeset{source: %GtfsVersion{}}

  """
  def changeset(gtfs_version, attrs) do
    gtfs_version
    |> cast(attrs, [:name])
    |> update_change(:name, fn
      name when is_binary(name) -> String.trim(name)
      other -> other
    end)
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
end
