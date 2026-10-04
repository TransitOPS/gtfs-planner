defmodule GtfsPlanner.Agents.Pack do
  @moduledoc """
  Behaviour every capability pack implements.

  Packs are code-owned: `GtfsPlanner.Agents.packs/0` is the only place the agent
  core names a pack, and a pack is never resolved from data, tool arguments or
  configuration.
  """

  alias GtfsPlanner.Agents.Scope

  @typedoc """
  One tool the model may call.

  `parameters` is a JSON Schema object with string keys: `"type" => "object"`,
  `"properties"`, `"required"` and `"additionalProperties" => false`. `activity`
  is the past-tense label the panel shows for the tool that ran.
  """
  @type tool :: %{
          name: String.t(),
          description: String.t(),
          parameters: map(),
          activity: String.t()
        }

  @typedoc """
  Bounded, server-created evidence for one tool result (INV-2).

  Evidence is the answer the panel trusts. It is built by the pack from the same
  read as the result it describes, it never contains model output, and the panel
  renders its counts, completeness, source and receipts from here. The model may
  contradict it; the prose below the card stays prose.

  `kind` names the answer, `title` its subject, `total`/`total_label` the exact
  authoritative count and `facts` the server-computed details beside it.
  `completeness` is `:complete` or `:incomplete` with a `completeness_reason`, so
  a bounded answer is never shown as a complete one. `source_ref` names the
  source read, `digest` is its content digest and `source_revision` stays `nil`
  until a real native revision exists. `scope` records the resolved scope the
  read ran under, `exclusions` the rows deliberately left out and `resources` the
  typed references the panel may resolve into allowlisted application links. A
  pack whose answer is a set of per-row records adds `rows`, the same records its
  own result reports, so a host may render an official card from the evidence
  without re-deriving any of it.
  """
  @type evidence :: %{
          required(:kind) => String.t(),
          required(:title) => String.t(),
          required(:total) => non_neg_integer(),
          required(:total_label) => String.t(),
          required(:completeness) => :complete | :incomplete,
          required(:source_ref) => String.t(),
          required(:digest) => String.t(),
          required(:source_revision) => String.t() | nil,
          required(:scope) => %{
            required(:organization_id) => String.t(),
            required(:gtfs_version_id) => String.t(),
            required(:identity) => String.t() | nil
          },
          required(:exclusions) => [String.t()],
          required(:resources) => [
            %{
              required(:kind) => String.t(),
              required(:id) => String.t(),
              optional(:label) => String.t()
            }
          ],
          optional(:completeness_reason) => String.t() | nil,
          optional(:facts) => [%{required(:label) => String.t(), required(:value) => String.t()}],
          optional(:rows) => [map()]
        }

  @typedoc """
  A change a pack prepared but did not apply.

  `summary` carries the generic copy the panel renders; `command` is the
  section-specific value that only the owning LiveView interprets. `bound_to`
  is the optional record of what the proposal was made against (the Alerts pack
  names an alert revision and a schedule token), which the owning LiveView hands
  back to the command that writes it.
  """
  @type prepared :: %{
          required(:summary) => %{title: String.t(), detail: String.t(), lines: [String.t()]},
          required(:command) => term(),
          optional(:bound_to) => map()
        }

  @doc "Stable pack identifier, also used as the session scope's `pack_id`."
  @callback id() :: String.t()

  @doc "Panel title, for example \"Calendar helper\"."
  @callback title() :: String.t()

  @doc "One sentence of scope shown before the first conversation starts."
  @callback intro() :: String.t()

  @doc "Two example requests offered as buttons in the first-conversation state."
  @callback examples() :: [String.t()]

  @doc "The pack's `SKILL.md` body without front matter, embedded at compile time."
  @callback skill() :: String.t()

  @doc "The tools the model may call."
  @callback tools() :: [tool()]

  @doc """
  Runs one tool for an authorized scope.

  A tool with a server-readable answer returns `{:ok, result, evidence}`; a tool
  with nothing to prove returns `{:ok, result}`. The prepared forms carry the
  same optional evidence. Return `{:error, message}` for a problem the model
  should read and correct; a raised exception is handled by the caller as a
  failed turn.
  """
  @callback call(name :: String.t(), args :: map(), Scope.t()) ::
              {:ok, map()}
              | {:ok, map(), evidence()}
              | {:prepared, prepared(), map()}
              | {:prepared, prepared(), map(), evidence()}
              | {:error, String.t()}

  @doc """
  Optional, code-owned check of the conversation's own resource context.

  It runs before the provider request, every tool, a delivered result and a
  prepared lookup, so a pack whose own preconditions are gone (a pack that
  prepared a date change, for example) sends no request, reads no data and hands
  off nothing. `{:error, :unavailable}` is the single refusal: the same result an
  absent, foreign or deleted resource produces, so no other organization's or
  version's metadata can reach the model.
  """
  @callback authorize_context(Scope.t()) :: :ok | {:error, :unavailable}

  @optional_callbacks authorize_context: 1

  @doc """
  The `scope` an evidence card records: the organization, version and the
  `"route:<uuid>"` or `"version:<uuid>"` identity label `AgentPanel` compares.
  """
  @spec evidence_scope(Scope.t()) :: %{
          organization_id: String.t(),
          gtfs_version_id: String.t(),
          identity: String.t() | nil
        }
  def evidence_scope(%Scope{} = scope) do
    identity =
      case Scope.identity(scope) do
        {kind, id} -> "#{kind}:#{id}"
        nil -> nil
      end

    %{
      organization_id: scope.organization_id,
      gtfs_version_id: scope.gtfs_version_id,
      identity: identity
    }
  end

  @doc """
  Runs `pack`'s optional `authorize_context/1` callback, or `:ok` for a pack
  without one.
  """
  @spec authorize_context(module(), Scope.t()) :: :ok | {:error, :unavailable}
  def authorize_context(pack, %Scope{} = scope) do
    if Code.ensure_loaded?(pack) and function_exported?(pack, :authorize_context, 1) do
      pack.authorize_context(scope)
    else
      :ok
    end
  end
end
