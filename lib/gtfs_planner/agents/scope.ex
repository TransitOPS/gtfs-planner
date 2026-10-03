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

  `alert_schedule_token` is the organization's active-schedule selection token
  (`Versions.selection_token()`) the Alerts conversation was opened under. The
  Alerts pack reads the active schedule, not any version the person selected, so
  its session key carries this token and the pack refuses every request, tool and
  delivered result once the organization's selection has moved on, including an
  A -> B -> A return. Every other pack leaves it `nil`.

  A host may also admit an immutable copy of the source a person is working from
  through `with_source_snapshot/2`. The copy is ephemeral and lives only in this
  map: the panel drops it when the context is replaced, and a lost source is
  re-pasted rather than retained. The server normalizes the envelope, hashes the
  normalized `{kind, payload}` itself, and refuses a caller-supplied digest key on
  the envelope, so a pack tool reads source content the server admitted rather
  than content a model or a tool argument asserts. That exactness is about the
  envelope's own keys and nothing else: a *payload* field named `digest` is
  ordinary source content — a feed manifest's, or a content hash column's — and
  is admitted and kept, because the envelope's digest is the server's own hash
  and never reads anything the caller put in the payload. Admission is bounded by the whole serialized
  resource context, not by the payload alone, and `authorized_context/1` re-checks
  shape, digest and that byte limit on every boundary, so replacing a Calendar
  approval or the payload cannot smuggle an oversized or tampered source past the
  cap (FH-1). `context_digest/1` binds the approval and the snapshot together as
  the session key, which is the one function `GtfsPlanner.Agents` names.
  """

  alias GtfsPlanner.Authorization
  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.AuditContext
  alias GtfsPlanner.Values
  alias GtfsPlanner.Versions

  @max_approval_length 2_000
  @max_snapshot_kind_length 64
  @max_payload_depth 32
  @max_context_bytes 65_536
  @max_finite_float 1.797_693_134_862_315_7e308

  @enforce_keys [:organization_id, :gtfs_version_id, :user_id, :pack_id]
  defstruct [
    :organization_id,
    :gtfs_version_id,
    :user_id,
    :user_email,
    :pack_id,
    :version_name,
    :subject_id,
    :alert_schedule_token,
    resource_context: %{identity: nil, approved_extension: nil, source_snapshot: nil}
  ]

  @typedoc "Which page this conversation belongs to."
  @type identity :: {:version, Ecto.UUID.t()} | {:route, Ecto.UUID.t()}

  @typedoc "An editor's approval, copied here by a server-observed native form action."
  @type approved_extension :: %{
          service_id: String.t(),
          end_date: Date.t(),
          approval_text: String.t()
        }

  @typedoc "A JSON-compatible value; the only shape a snapshot payload may hold."
  @type json_value ::
          String.t()
          | number()
          | boolean()
          | nil
          | [json_value()]
          | %{optional(String.t()) => json_value()}

  @typedoc """
  An immutable, server-hashed copy of the source a host admitted for the helper.

  `kind` names the source in a host's own words, `payload` is the normalized
  JSON-compatible content and `digest` is the server's hash of the normalized
  `{kind, payload}`. A snapshot is an admission record, not authority: it never
  states that a source is an agency-approved timetable.
  """
  @type source_snapshot :: %{
          required(:kind) => String.t(),
          required(:payload) => %{optional(String.t()) => json_value()},
          required(:digest) => String.t()
        }

  @typedoc """
  The server-owned resource context, never read from model output.

  `source_snapshot` is optional because a host that creates a context before it
  has a source to admit builds the two original keys, and such a context is read
  as carrying no snapshot.
  """
  @type resource_context :: %{
          required(:identity) => identity() | nil,
          required(:approved_extension) => approved_extension() | nil,
          optional(:source_snapshot) => source_snapshot() | nil
        }

  @type t :: %__MODULE__{
          organization_id: Ecto.UUID.t(),
          gtfs_version_id: Ecto.UUID.t() | nil,
          user_id: Ecto.UUID.t(),
          user_email: String.t() | nil,
          pack_id: String.t(),
          version_name: String.t() | nil,
          subject_id: Ecto.UUID.t() | nil,
          alert_schedule_token: Versions.selection_token() | nil,
          resource_context: resource_context()
        }

  @doc """
  Builds a resource context for `identity` with no approved extension or source snapshot.

  `nil` is the context of a conversation bound to no version resource, which is
  what an organization-owned conversation about one record uses.
  """
  @spec context(identity() | nil) :: resource_context()
  def context(identity),
    do: %{identity: identity, approved_extension: nil, source_snapshot: nil}

  @doc """
  Returns `context` with an admitted immutable source snapshot.

  `snapshot` is exactly `%{kind: kind, payload: payload}`: `kind` is a nonblank
  string of at most 64 characters, and `payload` is a string-key map of strings,
  finite numbers, booleans, `nil` and further maps or lists of the same. Anything
  else, including a caller-supplied `:digest`, is `{:error, :invalid_snapshot}`,
  because only the server may say what a payload hashes to.

  That exactness is about the envelope's keys and nothing else. `payload` is
  content, so a source that carries its own content hash under `"digest"` is
  admitted and keeps that field; it can never stand in for the envelope's digest,
  which this function always computes itself.

  The admitted context is refused with `{:error, :too_large}` when its whole
  serialized form, identity and approval and this envelope included, exceeds
  65,536 bytes. The original context is returned unchanged in every error case,
  so a refused source never becomes a half-attached one.
  """
  @spec with_source_snapshot(resource_context(), map()) ::
          {:ok, resource_context()} | {:error, :invalid_snapshot | :too_large}
  def with_source_snapshot(context, snapshot) when is_map(context) and is_map(snapshot) do
    if Enum.sort(Map.keys(snapshot)) == [:kind, :payload] do
      admit_snapshot(context, snapshot)
    else
      {:error, :invalid_snapshot}
    end
  end

  def with_source_snapshot(_context, _snapshot), do: {:error, :invalid_snapshot}

  @doc """
  The admitted source snapshot this conversation may read, or `nil`.

  A context that predates snapshots, or one whose snapshot never passed
  `with_source_snapshot/2`, reads as no snapshot; `authorized_context/1` is what
  refuses the second case before any provider request, tool read, delivered
  result or prepared lookup.

  This is a plain read and recomputes nothing. The stored digest is the server's
  own hash of server-admitted content, this map is built by the server rather than
  by a client, and every boundary that could observe a replacement is already
  behind `authorized_context/1`, which re-checks shape, digest and the byte limit.
  Re-hashing the envelope per read would `term_to_binary/1` a payload of up to
  64KiB on a hot tool path, and reporting a mismatch here as `nil` would make a
  tampered snapshot indistinguishable from no snapshot at all, where
  `authorized_context/1` refuses it as `{:error, :unavailable}` instead.
  """
  @spec source_snapshot(t()) :: source_snapshot() | nil
  def source_snapshot(%__MODULE__{resource_context: context}) do
    case context do
      %{source_snapshot: snapshot} -> snapshot
      _other -> nil
    end
  end

  @doc """
  The byte ceiling this module admits a whole resource context under.

  This is the ceiling `with_source_snapshot/2` enforces at admission and
  `authorized_context/1` re-checks at every boundary, so a host states this
  number to the person instead of a copy of it that can drift from the limit
  actually enforced here. Reading it changes nothing: the ceiling is not part of
  the context, and `context_digest/1` does not read it.
  """
  @spec max_context_bytes() :: pos_integer()
  def max_context_bytes, do: @max_context_bytes

  # The envelope is rebuilt here from the two admitted fields and the server's own
  # hash, so nothing a caller supplied survives inside it. Nothing inside
  # `payload` is filtered or renamed: a source's own `"digest"` field is content
  # the host copied, not a claim about the envelope beside it.
  defp admit_snapshot(context, %{kind: kind, payload: payload}) do
    if valid_kind?(kind) and map_payload?(payload) do
      snapshot = %{kind: kind, payload: payload, digest: snapshot_digest(kind, payload)}
      admitted = Map.put(context, :source_snapshot, snapshot)

      if oversize?(admitted), do: {:error, :too_large}, else: {:ok, admitted}
    else
      {:error, :invalid_snapshot}
    end
  end

  defp valid_kind?(kind) when is_binary(kind),
    do: String.length(kind) in 1..@max_snapshot_kind_length and String.trim(kind) != ""

  defp valid_kind?(_kind), do: false

  # The payload's top level is a string-key map, as `source_snapshot/0` and
  # `with_source_snapshot/2` document; `json_value?/2` alone would admit a bare
  # list, string, number, boolean or `nil` there, so the map check is made
  # separately and the per-value recursion still governs every entry.
  defp map_payload?(payload) when is_map(payload), do: json_value?(payload, 0)
  defp map_payload?(_payload), do: false

  # The depth bound is a safety floor, not a product limit: `json_value?/2`
  # recurses, and an untrusted payload is exactly where an unbounded nesting
  # would exhaust the stack before any refusal could be returned.
  defp json_value?(_term, depth) when depth > @max_payload_depth, do: false

  defp json_value?(term, _depth) when is_binary(term) or is_boolean(term) or is_nil(term),
    do: true

  defp json_value?(term, _depth) when is_integer(term), do: true
  defp json_value?(term, _depth) when is_float(term), do: finite?(term)

  defp json_value?(term, depth) when is_list(term),
    do: Enum.all?(term, &json_value?(&1, depth + 1))

  defp json_value?(term, depth) when is_map(term) do
    Enum.all?(Map.keys(term), &is_binary/1) and
      Enum.all?(term, fn {_key, value} -> json_value?(value, depth + 1) end)
  end

  defp json_value?(_term, _depth), do: false

  # Elixir's own arithmetic cannot overflow to a non-finite float, but a float
  # can arrive from outside this process — a NIF, or decoded bytes — and JSON
  # has no spelling for one. Comparing against the largest finite float refuses
  # both infinities and any NaN, whose every comparison is false.
  defp finite?(float), do: abs(float) < @max_finite_float

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
    |> hex_sha256()
  end

  @doc """
  The digest binding this conversation's approved extension and source snapshot.

  Both are hashed into one value, so a conversation that follows an approval is
  never the conversation that followed the same approval with different source
  attached, and a host that swaps the source starts a different conversation
  rather than continuing one whose tools were answered from the old source
  (INV-1). `approved_digest/1` stays available unchanged for a host that needs to
  reason about the approval alone.

  The snapshot contributes its `kind` and its content, not the server's digest
  of them: one payload admitted under two kinds is two conversations, and a
  context with no snapshot hashes the string `"none"` in that position, so the
  two cases are distinct and neither can raise.
  """
  @spec context_digest(t()) :: String.t()
  def context_digest(%__MODULE__{} = scope) do
    [approved_digest(scope), source_snapshot_term(source_snapshot(scope))]
    |> hex_sha256()
  end

  defp source_snapshot_term(nil), do: "none"
  defp source_snapshot_term(%{kind: kind, payload: payload}), do: {:snapshot, kind, payload}
  defp source_snapshot_term(other), do: other

  defp snapshot_digest(kind, payload), do: hex_sha256({kind, payload})

  defp hex_sha256(term) do
    term
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
    with :ok <- resolve_identity(scope),
         :ok <- resolve_approved(scope),
         :ok <- resolve_snapshot(scope) do
      # Measured last, on the whole context: an approval or identity swapped for
      # a larger one after admission cannot carry an already-admitted envelope
      # past the cap.
      if oversize?(scope.resource_context), do: {:error, :unavailable}, else: :ok
    end
  end

  # The digest is the server's, so a snapshot whose content no longer hashes to
  # it was replaced after admission and is refused before anything reads it.
  defp resolve_snapshot(%__MODULE__{} = scope) do
    case source_snapshot(scope) do
      nil ->
        :ok

      %{kind: kind, payload: payload, digest: digest} = snapshot ->
        if map_size(snapshot) == 3 and valid_kind?(kind) and map_payload?(payload) and
             digest == snapshot_digest(kind, payload) do
          :ok
        else
          {:error, :unavailable}
        end

      _other ->
        {:error, :unavailable}
    end
  end

  # The whole serialized resource context is measured, not the payload: an
  # oversized identity, approval or envelope refuses the same source a small one
  # would admit (FH-1, PM-1). Each part is encoded by its own explicit fields —
  # a tagged identity, ISO approval dates, the snapshot envelope — so a struct or
  # a tuple is never handed to the encoder and the measured bytes are the bytes
  # the JSON-safe context actually serializes to.
  defp oversize?(context) do
    context
    |> serialized_context()
    |> Jason.encode!()
    |> byte_size()
    |> Kernel.>(@max_context_bytes)
  end

  defp serialized_context(context) do
    %{
      "identity" => encoded_identity(context_value(context, :identity)),
      "approved_extension" => encoded_approved(context_value(context, :approved_extension)),
      "source_snapshot" => encoded_snapshot(context_value(context, :source_snapshot))
    }
  end

  defp context_value(context, key) when is_map(context) do
    case context do
      %{^key => value} -> value
      _other -> nil
    end
  end

  defp context_value(_context, _key), do: nil

  defp encoded_identity({kind, id}) when is_atom(kind) and is_binary(id),
    do: %{"kind" => Atom.to_string(kind), "id" => id}

  defp encoded_identity(_other), do: nil

  defp encoded_approved(%{
         service_id: service_id,
         end_date: %Date{} = end_date,
         approval_text: text
       })
       when is_binary(service_id) and is_binary(text),
       do: %{
         "service_id" => service_id,
         "end_date" => Date.to_iso8601(end_date),
         "approval_text" => text
       }

  defp encoded_approved(_other), do: nil

  defp encoded_snapshot(%{kind: kind, payload: payload, digest: digest})
       when is_binary(kind) and is_binary(digest) and is_map(payload),
       do: %{"kind" => kind, "payload" => json_value(payload), "digest" => digest}

  defp encoded_snapshot(_other), do: nil

  # Measurement never raises on a payload some other code built: a value that is
  # not JSON-compatible contributes its inspected form, which changes the byte
  # count but leaves the shape, and therefore the refusal, the same.
  defp json_value(term) when is_binary(term) or is_boolean(term) or is_nil(term), do: term
  defp json_value(term) when is_integer(term), do: term

  defp json_value(term) when is_float(term),
    do: if(finite?(term), do: term, else: inspect(term))

  defp json_value(term) when is_list(term), do: Enum.map(term, &json_value/1)

  defp json_value(term) when is_map(term) do
    if Enum.all?(Map.keys(term), &is_binary/1) do
      Map.new(term, fn {key, value} -> {key, json_value(value)} end)
    else
      inspect(term)
    end
  end

  defp json_value(term), do: inspect(term)

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
