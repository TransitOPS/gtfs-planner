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
  A change a pack prepared but did not apply.

  `summary` carries the generic copy the panel renders; `command` is the
  section-specific value that only the owning LiveView interprets.
  """
  @type prepared :: %{
          summary: %{title: String.t(), detail: String.t(), lines: [String.t()]},
          command: term()
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

  Return `{:error, message}` for a problem the model should read and correct; a
  raised exception is handled by the caller as a failed turn.
  """
  @callback call(name :: String.t(), args :: map(), Scope.t()) ::
              {:ok, map()} | {:prepared, prepared(), map()} | {:error, String.t()}
end
