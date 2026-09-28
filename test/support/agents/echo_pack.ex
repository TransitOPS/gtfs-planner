defmodule GtfsPlanner.Agents.EchoPack do
  @moduledoc """
  Test-only pack: a second, independent caller of the agent core.

  It has no domain code, so a passing run through `Dispatch`, `Turn` and
  `Session` proves those modules stay generic.
  """

  @behaviour GtfsPlanner.Agents.Pack

  alias GtfsPlanner.Agents.Scope

  @impl true
  def id, do: "echo"

  @impl true
  def title, do: "Echo helper"

  @impl true
  def intro, do: "I repeat the text you send me."

  @impl true
  def examples, do: ["Echo hello", "Echo a longer sentence."]

  @impl true
  def skill, do: "Echo the text you are given."

  @impl true
  def tools do
    [
      %{
        name: "echo",
        description: "Returns the text and the calling scope's organization.",
        activity: "Echoed text",
        parameters: %{
          "type" => "object",
          "properties" => %{"text" => %{"type" => "string"}},
          "required" => ["text"],
          "additionalProperties" => false
        }
      }
    ]
  end

  @impl true
  def call("echo", %{"text" => text}, %Scope{} = scope) do
    notify("echo")

    if text == "raise" do
      raise "echo pack was asked to raise"
    end

    {:ok, %{"text" => text, "organization_id" => scope.organization_id}}
  end

  defp notify(name) do
    case Application.get_env(:gtfs_planner, :echo_pack_test_pid) do
      pid when is_pid(pid) ->
        send(pid, {:echo_pack_called, name})
        :ok

      _unset ->
        :ok
    end
  end
end
