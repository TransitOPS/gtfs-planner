defmodule GtfsPlanner.FeedPublishing.Publication do
  @moduledoc """
  One organization's channel state: what it intends to publish and what the served
  manifest last proved.

  A row exists per `(organization_id, channel)` and lives under the claimed
  `namespace_id`. It owns durable intent (`desired_revision`, `next_sequence`),
  the receipts observed from the served manifest (`manifest_bytes`, its hash,
  ETag, generation, sequence and the provider's last-modified instant), and the
  bounded failure state a worker reports (`status`, `next_retry_at`,
  `last_error`). It never holds ZIP or feed bytes.

  `status` is one of `never_published`, `pending`, `staging`, `switching`,
  `reconciling`, `current`, `failed` or `blocked`. `disabled` is derived from
  configuration and is never stored, so disabling never rewrites history.

  `active_attempt_id` names this channel's current attempt through a composite
  `(active_attempt_id, organization_id)` foreign key, so a channel cannot point
  at another organization's attempt.
  """

  use Ecto.Schema

  alias GtfsPlanner.FeedPublishing.Attempt
  alias GtfsPlanner.FeedPublishing.Namespace
  alias GtfsPlanner.Organizations.Organization

  @channels [:full, :flex, :pathways, :alerts]

  @statuses [
    :never_published,
    :pending,
    :staging,
    :switching,
    :reconciling,
    :current,
    :failed,
    :blocked
  ]

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          organization_id: Ecto.UUID.t(),
          namespace_id: Ecto.UUID.t(),
          channel: atom(),
          desired_revision: integer(),
          next_sequence: integer(),
          active_attempt_id: Ecto.UUID.t() | nil,
          manifest_bytes: binary() | nil,
          manifest_sha256: String.t() | nil,
          manifest_etag: String.t() | nil,
          manifest_generation: String.t() | nil,
          manifest_sequence: integer() | nil,
          manifest_last_modified: DateTime.t() | nil,
          last_refresh_at: DateTime.t() | nil,
          status: atom(),
          next_retry_at: DateTime.t() | nil,
          last_error: String.t() | nil,
          retired_through_sequence: integer(),
          cleanup_cursor: String.t() | nil,
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  @doc "The four publishable channels: full, flex, pathways and alerts."
  @spec channels() :: [atom()]
  def channels, do: @channels

  @doc "The stored channel statuses. `disabled` is derived, never stored."
  @spec statuses() :: [atom()]
  def statuses, do: @statuses

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "feed_publications" do
    field :channel, Ecto.Enum, values: @channels
    field :desired_revision, :integer, default: 0
    field :next_sequence, :integer, default: 1

    field :manifest_bytes, :binary
    field :manifest_sha256, :string
    field :manifest_etag, :string
    field :manifest_generation, :string
    field :manifest_sequence, :integer
    field :manifest_last_modified, :utc_datetime_usec
    field :last_refresh_at, :utc_datetime_usec

    field :status, Ecto.Enum, values: @statuses, default: :never_published
    field :next_retry_at, :utc_datetime_usec
    field :last_error, :string

    field :retired_through_sequence, :integer, default: 0
    field :cleanup_cursor, :string

    belongs_to :organization, Organization
    belongs_to :namespace, Namespace
    belongs_to :active_attempt, Attempt

    timestamps(type: :utc_datetime_usec)
  end
end
