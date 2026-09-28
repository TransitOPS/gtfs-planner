defmodule GtfsPlanner.Agents.Scope do
  @moduledoc """
  The server-held identity of one helper conversation.

  A scope is built from LiveView assigns, never from model output: tool calls read
  the organization, service version and user only from here. `authorize/1` re-reads
  the membership on every call, so access withdrawn mid-conversation stops the next
  provider request and tool call.
  """

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Accounts.UserOrgMembership
  alias GtfsPlanner.Gtfs.AuditContext

  @editor_role "pathways_studio_editor"

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
    with true <- uuid?(user_id),
         true <- uuid?(organization_id),
         %UserOrgMembership{} = membership <-
           Accounts.get_user_org_membership(user_id, organization_id),
         true <- is_nil(membership.deactivated_at),
         true <- editor_role?(membership.roles) do
      :ok
    else
      _other -> {:error, :forbidden}
    end
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

  defp uuid?(value) when is_binary(value), do: match?({:ok, _}, Ecto.UUID.cast(value))
  defp uuid?(_value), do: false

  defp editor_role?(roles) when is_list(roles), do: @editor_role in roles
  defp editor_role?(_roles), do: false
end
