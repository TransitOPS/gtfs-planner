defmodule GtfsPlanner.Organizations.Organization do
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          alias: String.t(),
          name: String.t(),
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "organizations" do
    field :alias, :string
    field :name, :string

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
    |> cast(attrs, [:alias, :name])
    |> normalize_alias()
    |> validate_required([:alias, :name])
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
