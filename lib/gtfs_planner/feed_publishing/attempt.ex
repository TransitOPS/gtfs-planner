defmodule GtfsPlanner.FeedPublishing.Attempt do
  @moduledoc """
  One frozen, retryable publication of a channel's current content.

  An attempt records the exact bytes it will install (`manifest_body` and its
  hash), the condition it must replace (`predecessor_etag`, `nil` for a first
  creation), the sequence and fresh public generation it was allocated, and the
  accepted revisions it included. Those values are written once and never change:
  a changed predecessor requires a new authorized attempt with a new generation.

  `object_receipts` holds the immutable payload receipts this attempt confirmed
  and `private_snapshot` the bounded private realtime model behind it; neither
  is public content. `actor_id` and `provenance` are audit values retained after
  a user leaves the organization.

  `lease_token` and `lease_expires_at` fence the local worker, `retired_at` marks
  a resolved superseded attempt whose objects may eventually be collected.
  Unresolved and current attempts are retained instead of being appended to a
  per-heartbeat history.
  """

  use Ecto.Schema

  alias GtfsPlanner.Accounts.User
  alias GtfsPlanner.FeedPublishing.Publication
  alias GtfsPlanner.Organizations.Organization

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          publication_id: Ecto.UUID.t(),
          organization_id: Ecto.UUID.t(),
          sequence: integer(),
          generation: String.t(),
          desired_revision: integer(),
          manifest_body: binary(),
          manifest_sha256: String.t(),
          predecessor_etag: String.t() | nil,
          object_receipts: map(),
          private_snapshot: map() | nil,
          included_revisions: map(),
          actor_id: Ecto.UUID.t() | nil,
          provenance: String.t() | nil,
          lease_token: String.t() | nil,
          lease_expires_at: DateTime.t() | nil,
          state: String.t(),
          retired_at: DateTime.t() | nil,
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "feed_publication_attempts" do
    field :sequence, :integer
    field :generation, :string
    field :desired_revision, :integer

    field :manifest_body, :binary
    field :manifest_sha256, :string
    field :predecessor_etag, :string

    field :object_receipts, :map, default: %{}
    field :private_snapshot, :map
    field :included_revisions, :map, default: %{}

    field :provenance, :string

    field :lease_token, :string
    field :lease_expires_at, :utc_datetime_usec
    field :state, :string
    field :retired_at, :utc_datetime_usec

    belongs_to :publication, Publication
    belongs_to :organization, Organization
    belongs_to :actor, User

    timestamps(type: :utc_datetime_usec)
  end
end
