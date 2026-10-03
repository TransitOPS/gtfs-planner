defmodule GtfsPlanner.FeedPublishing.Namespace do
  @moduledoc """
  The permanent public prefix one organization claimed for its feeds.

  The prefix is the organization short name captured at the first deliberate
  publication, not GTFS `agency_id` and not the organization database id. It is
  claimed once: a later alias rename leaves the prefix, its `public_claim` and
  every published object where they are, and `FeedPublishing.claim_namespace/1`
  returns the same row rather than a renamed one.

  Uniqueness of `organization_id`, `prefix` and `public_claim` is decided by the
  table's unique indexes, so two racing first claims resolve to one owner in the
  database. The foreign key to the organization is `ON DELETE RESTRICT`: while a
  claimed namespace exists, destructive organization teardown is refused.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias GtfsPlanner.Organizations.Organization

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          organization_id: Ecto.UUID.t(),
          prefix: String.t(),
          public_claim: String.t(),
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "feed_publication_namespaces" do
    field :prefix, :string
    field :public_claim, :string

    belongs_to :organization, Organization

    timestamps(type: :utc_datetime_usec)
  end

  @doc """
  Builds the changeset for a first claim.

  Every value is server-owned: organization from the trusted scope, prefix from the
  current alias and claim from fresh randomness, so nothing here is cast from a
  request. Uniqueness is decided by the table's unique indexes, not by this
  changeset, so it declares no `unique_constraint/3`.
  """
  @spec claim_changeset(Ecto.UUID.t(), String.t(), String.t()) :: Ecto.Changeset.t()
  def claim_changeset(organization_id, prefix, public_claim) do
    %__MODULE__{}
    |> change(%{
      organization_id: organization_id,
      prefix: prefix,
      public_claim: public_claim
    })
    |> validate_required([:organization_id, :prefix, :public_claim])
    |> validate_length(:prefix, max: 255)
  end
end
