defmodule GtfsPlanner.Gtfs.TodsGeneration do
  @moduledoc """
  The durable receipt of one completed TODS generator request.

  A receipt exists for one reason: a request whose reply was lost must be
  recoverable. It records what a scoped request produced — its normalized input,
  the source fingerprint it planned against, the ids it created and a small
  summary — so a same-token retry returns the original outcome instead of
  generating twice. It is not a task queue: only completed generations are
  stored, and no planning fact lives here that belongs to the domain tables.

  Every field is writer-assigned. Nothing is cast from user parameters, because
  the organization, version, actor and request identity are authority the
  generator establishes after it authorizes the caller, never transport values.
  """

  use Ecto.Schema
  import Ecto.Changeset, only: [change: 2, validate_required: 2]

  @required_fields [
    :organization_id,
    :gtfs_version_id,
    :request_id,
    :normalized_inputs,
    :source_fingerprint,
    :created_ids,
    :summary
  ]

  # Scoped request identity. The index name stays inside PostgreSQL's 63-character
  # limit so `unique_constraint/3` can name it exactly instead of guessing.
  @request_index :tods_generations_scope_request_id_index

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "tods_generations" do
    field :organization_id, Ecto.UUID
    field :gtfs_version_id, Ecto.UUID
    field :actor_id, Ecto.UUID

    field :request_id, Ecto.UUID
    field :normalized_inputs, :map, default: %{}
    field :source_fingerprint, :string
    field :created_ids, :map, default: %{}
    field :summary, :map, default: %{}

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          organization_id: Ecto.UUID.t(),
          gtfs_version_id: Ecto.UUID.t(),
          actor_id: Ecto.UUID.t() | nil,
          request_id: Ecto.UUID.t(),
          normalized_inputs: map(),
          source_fingerprint: String.t(),
          created_ids: map(),
          summary: map(),
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  @doc """
  Builds the changeset for one completed generation.

  Values are assigned rather than cast, because every one of them is supplied by
  the writer that authorized the request. The database decides the rest: a
  repeated scoped request collides with the unique index, and a version of
  another organization is refused by the composite foreign key.
  """
  @spec completion_changeset(t() | Ecto.Changeset.t(), map()) :: Ecto.Changeset.t()
  def completion_changeset(%__MODULE__{} = generation, attrs) do
    generation
    |> change(attrs)
    |> validate_required(@required_fields)
    |> Ecto.Changeset.unique_constraint(:request_id, name: @request_index)
    |> Ecto.Changeset.foreign_key_constraint(:organization_id)
    |> Ecto.Changeset.foreign_key_constraint(:gtfs_version_id,
      name: :tods_generations_version_organization_fkey
    )
  end
end
