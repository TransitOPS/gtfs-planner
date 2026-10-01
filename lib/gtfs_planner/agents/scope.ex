defmodule GtfsPlanner.Agents.Scope do
  @moduledoc """
  The server-held identity of one helper conversation.

  A scope is built from LiveView assigns, never from model output: tool calls read
  the organization, service version and user only from here. `authorize/1` re-reads
  the membership on every call, so access withdrawn mid-conversation stops the next
  provider request and tool call.
  """

  alias GtfsPlanner.Authorization
  alias GtfsPlanner.Gtfs.AuditContext

  @enforce_keys [:organization_id, :gtfs_version_id, :user_id, :pack_id]
  defstruct [
    :organization_id,
    :gtfs_version_id,
    :user_id,
    :user_email,
    :pack_id,
    :version_name
  ]

  @type t :: %__MODULE__{
          organization_id: Ecto.UUID.t(),
          gtfs_version_id: Ecto.UUID.t(),
          user_id: Ecto.UUID.t(),
          user_email: String.t() | nil,
          pack_id: String.t(),
          version_name: String.t() | nil
        }

  @doc """
  Returns `:ok` only for a UUID user and organization whose current membership is
  active and carries `pathways_studio_editor`.
  """
  @spec authorize(t()) :: :ok | {:error, :forbidden}
  def authorize(%__MODULE__{user_id: user_id, organization_id: organization_id}) do
    Authorization.authorize_editor(%{actor_id: user_id, organization_id: organization_id})
  end

  @doc """
  Builds the audit context for a change the person applies through the existing review.
  """
  @spec audit_context(t()) :: AuditContext.t()
  def audit_context(%__MODULE__{} = scope) do
    %AuditContext{
      organization_id: scope.organization_id,
      gtfs_version_id: scope.gtfs_version_id,
      station_stop_id: nil,
      actor_id: scope.user_id,
      actor_email: scope.user_email
    }
  end
end
