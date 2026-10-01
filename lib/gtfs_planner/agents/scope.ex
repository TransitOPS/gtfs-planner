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

  A resource context also carries an optional immutable `source_snapshot`: the
  accepted input source a host froze after a server-observed native form
  confirmation. `with_source_snapshot/2` admits it only as a bounded JSON-safe
  envelope, computes the digest itself (a caller-supplied digest is refused) and
  measures the whole serialized context against `max_context_bytes/0`;
  `source_snapshot/1` reads it back, and `context_digest/1` binds both the
  approval and the snapshot to the session key. The envelope only proves the
  snapshot was whole and server-measured: a pack still owns the resource
  identities inside a payload (INV-2).

  The session key carries `subject_id` and `context_digest/1` together: they
  answer different questions. `subject_id` separates two conversations about two
  different records, while `context_digest/1` separates two conversations about
  one record from two different accepted sources.
  """

  alias GtfsPlanner.Authorization
  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.AuditContext
  alias GtfsPlanner.Values
  alias GtfsPlanner.Versions

  @max_approval_length 2_000
  @max_context_bytes 65_536
  @max_snapshot_kind_length 64
  @max_payload_depth 12

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

  @typedoc """
  One immutable accepted source snapshot attached to a resource context.

  `payload` is the frozen, JSON-safe accepted source the host observed, and
  `digest` is computed here from the normalized envelope rather than supplied by
  the caller.
  """
  @type source_snapshot :: %{
          required(:kind) => String.t(),
          required(:payload) => map(),
          required(:digest) => String.t()
        }

  @typedoc "The server-owned resource context, never read from model output."
  @type resource_context :: %{
          required(:identity) => identity() | nil,
          required(:approved_extension) => approved_extension() | nil,
          required(:source_snapshot) => source_snapshot() | nil
        }

  @type t :: %__MODULE__{
          organization_id: Ecto.UUID.t(),
          gtfs_version_id: Ecto.UUID.t(),
          user_id: Ecto.UUID.t(),
          user_email: String.t() | nil,
          pack_id: String.t(),
          version_name: String.t() | nil,
          subject_id: Ecto.UUID.t() | nil,
          resource_context: resource_context()
        }

  @doc "Builds a resource context for `identity` with no approved extension."
  @spec context(identity()) :: resource_context()
  def context(identity),
    do: %{identity: identity, approved_extension: nil, source_snapshot: nil}

  @doc "The whole JSON-safe serialized resource context may not exceed this."
  @spec max_context_bytes() :: pos_integer()
  def max_context_bytes, do: @max_context_bytes

  @doc """
  Returns `context` with `snapshot` attached, or refuses it.

  `snapshot` is `%{kind: kind, payload: payload}`. `kind` is a nonblank string of
  at most 64 characters, and `payload` is a bounded JSON-compatible map with
  string keys: strings, finite numbers, booleans, `nil`, and nested maps and
  lists of the same. The envelope digest is computed here from the normalized
  `{kind, payload}`, so a caller cannot claim a digest for a payload this module
  did not measure; a snapshot map carrying its own `digest` key, or a payload
  carrying one, is refused outright.

  `{:error, :invalid_snapshot}` is a shape this module will not admit, and
  `{:error, :too_large}` is a whole resource context - identity, approval,
  envelope and payload together - over `max_context_bytes/0`, with equality
  allowed.
  """
  @spec with_source_snapshot(resource_context(), map()) ::
          {:ok, resource_context()} | {:error, :invalid_snapshot | :too_large}
  def with_source_snapshot(_context, %{digest: _digest}), do: {:error, :invalid_snapshot}
  def with_source_snapshot(_context, %{"digest" => _digest}), do: {:error, :invalid_snapshot}

  def with_source_snapshot(context, %{kind: kind, payload: payload})
      when is_map(context) do
    with {:ok, kind} <- normalize_kind(kind),
         :ok <- reject_caller_digest(payload),
         {:ok, payload} <- normalize_payload(payload, 0),
         snapshot = %{kind: kind, payload: payload, digest: snapshot_digest(kind, payload)},
         context = Map.put(context, :source_snapshot, snapshot),
         :ok <- measure_context(context) do
      {:ok, context}
    end
  end

  def with_source_snapshot(_context, _snapshot), do: {:error, :invalid_snapshot}

  @doc """
  Returns the immutable source snapshot this context carries, or `nil`.

  A server-created context that predates snapshots, and one with no accepted
  source, both read as absent rather than as a defect.
  """
  @spec source_snapshot(t() | resource_context()) :: source_snapshot() | nil
  def source_snapshot(%__MODULE__{resource_context: resource_context}),
    do: source_snapshot(resource_context)

  def source_snapshot(%{source_snapshot: snapshot}), do: snapshot

  # A server-created context from before snapshots existed reads as carrying
  # none, rather than raising on a key it never had.
  def source_snapshot(%{}), do: nil

  @doc """
  The canonical digest binding this context's approval and its source snapshot.

  Without a snapshot this is `approved_digest/1`, so a conversation that carries
  no accepted source keeps exactly the key it already had.
  """
  @spec context_digest(t()) :: String.t()
  def context_digest(%__MODULE__{} = scope) do
    case source_snapshot(scope) do
      nil -> approved_digest(scope)
      snapshot -> sha256([approved_digest(scope), snapshot.kind, snapshot.digest])
    end
  end

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
  # organization or version holds (AC-2).
  defp resolve_context(%__MODULE__{} = scope) do
    with :ok <- resolve_identity(scope),
         :ok <- resolve_approved(scope) do
      resolve_source_snapshot(scope)
    end
  end

  # The snapshot is re-measured and its digest recomputed on every check, so a
  # context mutated after admission - or one whose payload was never a shape
  # `with_source_snapshot/2` admits - cannot reach a provider request, a tool
  # read or a delivered result.
  defp resolve_source_snapshot(%__MODULE__{} = scope) do
    case source_snapshot(scope) do
      nil ->
        :ok

      %{kind: kind, payload: payload, digest: digest} ->
        with {:ok, kind} <- normalize_kind(kind),
             {:ok, payload} <- normalize_payload(payload, 0),
             true <- snapshot_digest(kind, payload) == digest,
             :ok <- measure_context(scope.resource_context) do
          :ok
        else
          _other -> {:error, :unavailable}
        end

      _other ->
        {:error, :unavailable}
    end
  end

  defp resolve_identity(%__MODULE__{} = scope) do
    case scope.resource_context do
      %{identity: {:route, id}} -> resolve_route(scope, id)
      %{identity: {:version, id}} -> resolve_version(scope, id)
      %{identity: nil} -> resolve_version(scope, scope.gtfs_version_id)
      _other -> {:error, :unavailable}
    end
  end

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
