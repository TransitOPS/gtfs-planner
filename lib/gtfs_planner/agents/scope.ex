defmodule GtfsPlanner.Agents.Scope do
  @moduledoc """
  The server-held identity of one helper conversation.

  A scope is built from LiveView assigns, never from model output: tool calls read
  the organization, service version, resource identity and user only from here.
  `authorize/1` re-reads the membership on every call, so access withdrawn
  mid-conversation stops the next provider request and tool call.

  `resource_context` names the page the conversation belongs to (INV-1):
  `{:version, id}` for a whole-version page such as Calendars and
  `{:route, id}` for a single route's Schedules page. The host replaces it through
  `AgentPanel.set_context/2` on ordinary navigation; pack arguments and model output
  never carry an identity. `authorized_context/1` resolves that identity inside the
  current organization and version on every check, and an absent, foreign or
  deleted resource returns the same `{:error, :unavailable}` as a malformed one, so
  no foreign metadata is disclosed. `approved_digest/1` binds an editor-submitted
  Calendar approval to the session key, so a conversation started before an
  approval is a different one.

  `subject_id` names the record one conversation is about — the alert of an
  assistant editor — and is `nil` for a conversation with no such record, such as
  Calendar's. It is part of the session key, so two alerts of one person and
  version get two conversations.

  `gtfs_version_id` is optional, and a scope with none is an organization-owned
  conversation rather than a broken one: the Alerts editor is about the alert,
  which belongs to the organization, so the version a person happens to have
  selected in the navigation is neither its identity nor the context its tools
  read. A pack derives whatever schedule context it needs from the subject row it
  already resolved (CR-4), and `resolve_identity/1` authorizes such a scope on its
  organization and subject instead of on a version. Every other host binds a
  version identity, so those conversations keep their exact version contract.
  """

  alias GtfsPlanner.Authorization
  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.AuditContext
  alias GtfsPlanner.Values
  alias GtfsPlanner.Versions

  @max_approval_length 2_000

  @enforce_keys [:organization_id, :gtfs_version_id, :user_id, :pack_id]
  defstruct [
    :organization_id,
    :gtfs_version_id,
    :user_id,
    :user_email,
    :pack_id,
    :version_name,
    :subject_id,
    resource_context: %{identity: nil, approved_extension: nil}
  ]

  @typedoc "Which page this conversation belongs to."
  @type identity :: {:version, Ecto.UUID.t()} | {:route, Ecto.UUID.t()}

  @typedoc "An editor's approval, copied here by a server-observed native form action."
  @type approved_extension :: %{
          service_id: String.t(),
          end_date: Date.t(),
          approval_text: String.t()
        }

  @typedoc "The server-owned resource context, never read from model output."
  @type resource_context :: %{
          required(:identity) => identity() | nil,
          required(:approved_extension) => approved_extension() | nil
        }

  @type t :: %__MODULE__{
          organization_id: Ecto.UUID.t(),
          gtfs_version_id: Ecto.UUID.t() | nil,
          user_id: Ecto.UUID.t(),
          user_email: String.t() | nil,
          pack_id: String.t(),
          version_name: String.t() | nil,
          subject_id: Ecto.UUID.t() | nil,
          resource_context: resource_context()
        }

  @doc """
  Builds a resource context for `identity` with no approved extension.

  `nil` is the context of a conversation bound to no version resource, which is
  what an organization-owned conversation about one record uses.
  """
  @spec context(identity() | nil) :: resource_context()
  def context(identity), do: %{identity: identity, approved_extension: nil}

  @doc """
  Returns `:ok` only for a UUID user and organization whose current membership is
  active and carries `pathways_studio_editor`.
  """
  @spec authorize(t()) :: :ok | {:error, :forbidden}
  def authorize(%__MODULE__{user_id: user_id, organization_id: organization_id}) do
    Authorization.authorize_editor(%{actor_id: user_id, organization_id: organization_id})
  end

  @doc """
  Returns the identity this conversation is bound to, or `nil` for a host that
  binds no single resource (the whole-version Calendar page's sessions before a
  host names one).
  """
  @spec identity(t()) :: identity() | nil
  def identity(%__MODULE__{resource_context: %{identity: identity}}), do: identity

  @doc """
  The editor's approved extension held in this scope's context, or `nil`.

  This value was copied here by a server-observed native form action, so it is
  the only approval a pack tool may read: a model paraphrase, a tool argument or
  an imported GTFS field cannot supply one.
  """
  @spec approved_extension(t()) :: approved_extension() | nil
  def approved_extension(%__MODULE__{resource_context: %{approved_extension: approved}}),
    do: approved

  @doc """
  The canonical digest of the approved extension in this scope's context.

  It is `"none"` without one, so the session key of a conversation that follows an
  approved input never matches the one before it (INV-1).
  """
  @spec approved_digest(t()) :: String.t()
  def approved_digest(%__MODULE__{resource_context: %{approved_extension: nil}}), do: "none"

  def approved_digest(%__MODULE__{resource_context: %{approved_extension: approved}}) do
    approved
    |> canonical_approved()
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  @doc """
  Authorizes the membership and then the resource identity of `scope`.

  Returns `:ok`, `{:error, :forbidden}` for a membership that is not an active
  editor's, or `{:error, :unavailable}` for a version or route the current
  organization and version cannot resolve. Both failures are checked before any
  provider request, tool read, delivered result or prepared lookup.
  """
  @spec authorized_context(t()) :: :ok | {:error, :forbidden | :unavailable}
  def authorized_context(%__MODULE__{} = scope) do
    with :ok <- authorize(scope) do
      resolve_context(scope)
    end
  end

  # An absent, foreign, deleted and malformed resource are the same result: the
  # caller learns that the page's resource is unavailable, never what another
  # organization or version holds (AC-2). A scope that binds no version names no
  # version resource, so there is nothing to resolve here: its pack's own
  # `authorize_context/1` is the boundary that re-reads its subject on every
  # request, tool call and delivered result.
  defp resolve_context(%__MODULE__{} = scope) do
    with :ok <- resolve_identity(scope) do
      resolve_approved(scope)
    end
  end

  defp resolve_identity(%__MODULE__{} = scope) do
    case scope.resource_context do
      %{identity: {:route, id}} -> resolve_route(scope, id)
      %{identity: {:version, id}} -> resolve_version(scope, id)
      %{identity: nil} -> resolve_scope_version(scope)
      _other -> {:error, :unavailable}
    end
  end

  # A host that bound no version is authorized by its organization alone; a host
  # that did is still checked against it, so a stale version-scoped panel keeps
  # refusing exactly as before.
  defp resolve_scope_version(%__MODULE__{gtfs_version_id: nil}), do: :ok

  defp resolve_scope_version(%__MODULE__{} = scope),
    do: resolve_version(scope, scope.gtfs_version_id)

  defp resolve_route(%__MODULE__{} = scope, id) do
    with :ok <- resolve_version(scope, scope.gtfs_version_id) do
      case Gtfs.get_route_in_version(scope.organization_id, scope.gtfs_version_id, id) do
        {:ok, _route} -> :ok
        {:error, :not_found} -> {:error, :unavailable}
      end
    end
  end

  # The identity version and the scope version are one value: a mismatch is a
  # stale panel, not a second authorized scope.
  defp resolve_version(%__MODULE__{} = scope, id) do
    if Values.uuid?(id) and id == scope.gtfs_version_id and
         not is_nil(Versions.get_gtfs_version_for_lifecycle(scope.organization_id, id)) do
      :ok
    else
      {:error, :unavailable}
    end
  end

  defp resolve_approved(%__MODULE__{} = scope) do
    case scope.resource_context do
      %{approved_extension: nil} ->
        :ok

      %{approved_extension: approved} ->
        with %{service_id: service_id, end_date: %Date{}, approval_text: text}
             when is_binary(text) <-
               approved,
             true <- is_binary(service_id),
             true <- String.length(text) in 1..@max_approval_length,
             true <- String.trim(text) != "",
             {:ok, _calendar} <-
               Gtfs.get_calendar_in_version(
                 scope.organization_id,
                 scope.gtfs_version_id,
                 service_id
               ) do
          :ok
        else
          _other -> {:error, :unavailable}
        end

      _other ->
        {:error, :unavailable}
    end
  end

  defp canonical_approved(%{service_id: service_id, end_date: end_date, approval_text: text}) do
    [service_id, Date.to_iso8601(end_date), text]
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
