defmodule GtfsPlanner.Agents.DispatchTest.ProbePack do
  @moduledoc """
  Test-only pack whose declared schema exercises the dispatch validator's whole
  subset: required keys, string `maxLength`, integer `minimum`, objects, and
  arrays with item types and item counts.
  """

  @behaviour GtfsPlanner.Agents.Pack

  alias GtfsPlanner.Agents.Scope

  @impl true
  def id, do: "probe"

  @impl true
  def title, do: "Probe helper"

  @impl true
  def intro, do: "Exercises the dispatch fence."

  @impl true
  def examples, do: ["Probe the schema", "Probe a payload."]

  @impl true
  def skill, do: "Probe the dispatch fence."

  @impl true
  def tools do
    [
      %{
        name: "probe",
        description: "Accepts the declared schema subset.",
        activity: "Probed the schema",
        parameters: %{
          "type" => "object",
          "properties" => %{
            "query" => %{"type" => "string", "maxLength" => 100},
            "offset" => %{"type" => "integer", "minimum" => 0},
            "window" => %{"type" => "object"},
            "dates" => %{
              "type" => "array",
              "items" => %{"type" => "string"},
              "minItems" => 1,
              "maxItems" => 3
            }
          },
          "required" => ["query"],
          "additionalProperties" => false
        }
      },
      %{
        name: "sized",
        description: "Returns a payload of the requested size.",
        activity: "Sized a payload",
        parameters: %{
          "type" => "object",
          "properties" => %{"bytes" => %{"type" => "integer", "minimum" => 0}},
          "required" => ["bytes"],
          "additionalProperties" => false
        }
      },
      %{
        name: "prepare",
        description: "Returns a prepared change with a payload.",
        activity: "Prepared a probe change",
        parameters: %{
          "type" => "object",
          "properties" => %{"bytes" => %{"type" => "integer", "minimum" => 0}},
          "required" => ["bytes"],
          "additionalProperties" => false
        }
      },
      %{
        name: "fail",
        description: "Returns a bounded pack error.",
        activity: "Failed",
        parameters: %{
          "type" => "object",
          "properties" => %{},
          "required" => [],
          "additionalProperties" => false
        }
      }
    ]
  end

  @impl true
  def call("probe", args, %Scope{}) do
    notify("probe")
    {:ok, %{"query" => args["query"], "offset" => args["offset"] || 0}}
  end

  def call("sized", %{"bytes" => bytes}, %Scope{}) do
    notify("sized")
    {:ok, %{"blob" => String.duplicate("x", bytes)}}
  end

  def call("prepare", %{"bytes" => bytes}, %Scope{}) do
    notify("prepare")

    prepared = %{
      summary: %{title: "Probe change", detail: "1 date", lines: ["Probe · 1 date"]},
      command: {:probe_change, bytes}
    }

    {:prepared, prepared, %{"blob" => String.duplicate("x", bytes)}}
  end

  def call("fail", _args, %Scope{}) do
    notify("fail")
    {:error, "Nothing to see here."}
  end

  # `Dispatch.call/4` runs in the test process, so `self/0` is the test's mailbox.
  defp notify(name), do: send(self(), {:probe_pack_called, name})
end

defmodule GtfsPlanner.Agents.DispatchTest do
  use GtfsPlanner.DataCase, async: false

  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Agents.Dispatch
  alias GtfsPlanner.Agents.DispatchTest.ProbePack
  alias GtfsPlanner.Agents.EchoPack
  alias GtfsPlanner.Agents.Scope

  # Step 9 extends this list with every value of `GtfsPlanner.Agents.packs/0`.
  @packs [EchoPack]

  @arguments_cap 32_768
  @result_cap 32_768

  @core_sources [
    "lib/gtfs_planner/agents/scope.ex",
    "lib/gtfs_planner/agents/pack.ex",
    "lib/gtfs_planner/agents/dispatch.ex",
    "lib/gtfs_planner/agents/prompt.ex",
    "lib/gtfs_planner/agents/model.ex",
    "lib/gtfs_planner/agents/turn.ex",
    "lib/gtfs_planner/agents/session.ex",
    "lib/gtfs_planner_web/live/agent_panel.ex",
    "lib/gtfs_planner_web/components/agent_components.ex"
  ]

  @forbidden_prefixes [
    [:GtfsPlanner, :Agents, :Packs],
    [:GtfsPlanner, :Agents, :EchoPack],
    [:GtfsPlanner, :Gtfs, :Calendars]
  ]

  setup do
    previous_pid = Application.get_env(:gtfs_planner, :echo_pack_test_pid)
    Application.put_env(:gtfs_planner, :echo_pack_test_pid, self())

    on_exit(fn ->
      if is_nil(previous_pid) do
        Application.delete_env(:gtfs_planner, :echo_pack_test_pid)
      else
        Application.put_env(:gtfs_planner, :echo_pack_test_pid, previous_pid)
      end
    end)

    :ok
  end

  describe "the authority fence" do
    test "rejects a tool the pack does not declare" do
      scope = active_scope()

      assert Dispatch.call(EchoPack, scope, "delete_route", ~s|{"text":"hi"}|) ==
               {:tool_error, "Unknown tool: delete_route"}

      refute_received {:echo_pack_called, _}
    end

    test "rejects arguments that are not a JSON object" do
      scope = active_scope()

      for arguments <- ["not json", "[1,2]", "null", "12"] do
        assert Dispatch.call(EchoPack, scope, "echo", arguments) ==
                 {:tool_error, "Arguments must be a JSON object."}
      end

      refute_received {:echo_pack_called, _}
    end

    test "rejects an undeclared organization_id before the pack runs" do
      scope = active_scope()
      other_organization = organization_fixture()

      assert Dispatch.call(
               EchoPack,
               scope,
               "echo",
               Jason.encode!(%{
                 "text" => "hi",
                 "organization_id" => other_organization.id
               })
             ) == {:tool_error, "Unexpected argument: organization_id"}

      refute_received {:echo_pack_called, _}
    end

    test "reports the first sorted undeclared scope key" do
      scope = active_scope()

      arguments =
        Jason.encode!(%{
          "user_id" => "user",
          "organization_id" => "org",
          "gtfs_version_id" => "version"
        })

      assert Dispatch.call(EchoPack, scope, "echo", arguments) ==
               {:tool_error, "Unexpected argument: gtfs_version_id"}

      refute_received {:echo_pack_called, _}
    end

    test "rejects every undeclared key of every tool in the pack list" do
      scope = active_scope()

      for pack <- @packs, tool <- pack.tools() do
        assert Dispatch.call(pack, scope, tool.name, ~s|{"organization_id":"other"}|) ==
                 {:tool_error, "Unexpected argument: organization_id"}
      end

      refute_received {:echo_pack_called, _}
    end

    test "runs no pack code when the membership is deactivated" do
      organization = organization_fixture()
      user = user_fixture()
      membership = organization_membership_fixture(user, organization)
      scope = scope_fixture(organization, user)

      assert Scope.authorize(scope) == :ok

      deactivate_membership_fixture(membership)

      assert Dispatch.call(EchoPack, scope, "echo", ~s|{"text":"hi"}|) == {:error, :forbidden}
      refute_received {:echo_pack_called, _}
    end

    test "returns the server-held organization even when the text looks like another organization" do
      scope = active_scope()
      other_organization = organization_fixture()

      assert Dispatch.call(
               EchoPack,
               scope,
               "echo",
               Jason.encode!(%{"text" => other_organization.id})
             ) ==
               {:ok,
                %{"text" => other_organization.id, "organization_id" => scope.organization_id}}

      assert_received {:echo_pack_called, "echo"}
    end

    test "treats empty and missing argument strings as an empty object" do
      scope = active_scope()

      for arguments <- ["", nil] do
        assert Dispatch.call(EchoPack, scope, "echo", arguments) ==
                 {:tool_error, "Missing required argument: text"}
      end

      refute_received {:echo_pack_called, _}
    end

    test "serves consecutive calls through the same pack and core" do
      scope = active_scope()

      assert Dispatch.call(EchoPack, scope, "echo", ~s|{"text":"one"}|) ==
               {:ok, %{"text" => "one", "organization_id" => scope.organization_id}}

      assert Dispatch.call(EchoPack, scope, "echo", ~s|{"text":"two"}|) ==
               {:ok, %{"text" => "two", "organization_id" => scope.organization_id}}

      assert_received {:echo_pack_called, "echo"}
      assert_received {:echo_pack_called, "echo"}
      refute_received {:echo_pack_called, _}
    end

    test "maps a pack error to a tool error" do
      scope = active_scope()

      assert Dispatch.call(ProbePack, scope, "fail", "{}") ==
               {:tool_error, "Nothing to see here."}

      assert_received {:probe_pack_called, "fail"}
    end

    test "does not rescue a raising pack" do
      scope = active_scope()

      assert_raise RuntimeError, fn ->
        Dispatch.call(EchoPack, scope, "echo", ~s|{"text":"raise"}|)
      end
    end
  end

  describe "declared argument validation" do
    test "rejects an undeclared key before validating declared values" do
      scope = active_scope()

      assert Dispatch.call(ProbePack, scope, "probe", ~s|{"organization_id":"org"}|) ==
               {:tool_error, "Unexpected argument: organization_id"}

      assert Dispatch.call(ProbePack, scope, "probe", ~s|{"query":12,"user_id":"user"}|) ==
               {:tool_error, "Unexpected argument: user_id"}

      refute_received {:probe_pack_called, _}
    end

    test "enforces required keys and non-null values" do
      scope = active_scope()

      assert Dispatch.call(ProbePack, scope, "probe", "{}") ==
               {:tool_error, "Missing required argument: query"}

      assert Dispatch.call(ProbePack, scope, "probe", ~s|{"query":null}|) ==
               {:tool_error, "Argument query must not be null."}

      assert Dispatch.call(ProbePack, scope, "probe", ~s|{"query":"ok","offset":null}|) ==
               {:tool_error, "Argument offset must not be null."}

      refute_received {:probe_pack_called, _}
    end

    test "rejects wrong declared types" do
      scope = active_scope()

      assert Dispatch.call(ProbePack, scope, "probe", ~s|{"query":12}|) ==
               {:tool_error, "Argument query must be a string."}

      assert Dispatch.call(ProbePack, scope, "probe", ~s|{"query":"ok","offset":"1"}|) ==
               {:tool_error, "Argument offset must be an integer."}

      assert Dispatch.call(ProbePack, scope, "probe", ~s|{"query":"ok","window":"now"}|) ==
               {:tool_error, "Argument window must be an object."}

      assert Dispatch.call(ProbePack, scope, "probe", ~s|{"query":"ok","dates":"today"}|) ==
               {:tool_error, "Argument dates must be an array."}

      refute_received {:probe_pack_called, _}
    end

    test "enforces string maxLength and integer minimum" do
      scope = active_scope()
      too_long = String.duplicate("a", 101)

      assert Dispatch.call(ProbePack, scope, "probe", Jason.encode!(%{"query" => too_long})) ==
               {:tool_error, "Argument query must be at most 100 characters."}

      assert Dispatch.call(ProbePack, scope, "probe", ~s|{"query":"ok","offset":-1}|) ==
               {:tool_error, "Argument offset must be at least 0."}

      refute_received {:probe_pack_called, _}
    end

    test "accepts string and integer values exactly at their declared bounds" do
      scope = active_scope()
      query = String.duplicate("a", 100)

      assert {:ok, %{"query" => ^query, "offset" => 0}} =
               Dispatch.call(
                 ProbePack,
                 scope,
                 "probe",
                 Jason.encode!(%{"query" => query, "offset" => 0})
               )

      assert_received {:probe_pack_called, "probe"}
    end

    test "enforces array item types and item counts" do
      scope = active_scope()

      assert Dispatch.call(ProbePack, scope, "probe", ~s|{"query":"ok","dates":[1,2]}|) ==
               {:tool_error, "Argument dates must contain only string values."}

      assert Dispatch.call(ProbePack, scope, "probe", ~s|{"query":"ok","dates":[]}|) ==
               {:tool_error, "Argument dates must have 1 or more items."}

      assert Dispatch.call(
               ProbePack,
               scope,
               "probe",
               ~s|{"query":"ok","dates":["a","b","c","d"]}|
             ) ==
               {:tool_error, "Argument dates must have 3 or fewer items."}

      refute_received {:probe_pack_called, _}
    end

    test "accepts an array exactly at its declared item bounds" do
      scope = active_scope()

      assert {:ok, _result} =
               Dispatch.call(ProbePack, scope, "probe", ~s|{"query":"ok","dates":["a","b","c"]}|)

      assert_received {:probe_pack_called, "probe"}
    end
  end

  describe "byte limits" do
    test "rejects raw arguments over the byte limit before decoding" do
      scope = active_scope()

      assert Dispatch.call(EchoPack, scope, "echo", echo_arguments_of_size(@arguments_cap + 1)) ==
               {:tool_error, "Arguments are too large."}

      refute_received {:echo_pack_called, _}
    end

    test "decodes arguments exactly at the byte limit and narrows an oversized result" do
      scope = active_scope()

      assert Dispatch.call(EchoPack, scope, "echo", echo_arguments_of_size(@arguments_cap)) ==
               {:tool_error, "Too much data for one result. Narrow the request."}

      assert_received {:echo_pack_called, "echo"}
    end

    test "passes a prepared result through unchanged" do
      scope = active_scope()

      assert {:prepared, %{summary: %{title: "Probe change"}, command: {:probe_change, 0}},
              %{"blob" => ""}} = Dispatch.call(ProbePack, scope, "prepare", ~s|{"bytes":0}|)

      assert_received {:probe_pack_called, "prepare"}
    end

    test "discards a prepared value when the serialized result is too large" do
      scope = active_scope()

      assert Dispatch.call(ProbePack, scope, "prepare", ~s|{"bytes":#{@result_cap}}|) ==
               {:tool_error, "Too much data for one result. Narrow the request."}

      assert_received {:probe_pack_called, "prepare"}
    end

    test "accepts a result exactly at the byte limit and rejects one byte more" do
      scope = active_scope()
      overhead = byte_size(Jason.encode!(%{"blob" => ""}))

      assert {:ok, %{"blob" => blob}} =
               Dispatch.call(ProbePack, scope, "sized", ~s|{"bytes":#{@result_cap - overhead}}|)

      assert byte_size(Jason.encode!(%{"blob" => blob})) == @result_cap

      assert Dispatch.call(ProbePack, scope, "sized", ~s|{"bytes":#{@result_cap - overhead + 1}}|) ==
               {:tool_error, "Too much data for one result. Narrow the request."}
    end
  end

  describe "the generic core" do
    test "lists no concrete pack and no calendar module in any core source" do
      checked = Enum.filter(@core_sources, &File.exists?/1)

      assert "lib/gtfs_planner/agents/scope.ex" in checked
      assert "lib/gtfs_planner/agents/pack.ex" in checked
      assert "lib/gtfs_planner/agents/dispatch.ex" in checked

      offenders =
        for path <- checked,
            reference <- path |> read_source() |> forbidden_references() do
          "#{path} names #{reference}"
        end

      assert offenders == []
    end

    test "the dependency check allows the standard library and the shared display clock" do
      assert forbidden_references(Code.string_to_quoted!(~s|Calendar.strftime(date, "%Y-%m-%d")|)) ==
               []

      assert forbidden_references(
               Code.string_to_quoted!(~s|GtfsPlanner.Gtfs.DisplayClock.label(nil)|)
             ) ==
               []
    end

    test "the dependency check rejects a concrete pack and the Calendars context" do
      assert forbidden_references(
               Code.string_to_quoted!(~s|alias GtfsPlanner.Agents.Packs.Calendars|)
             ) ==
               ["GtfsPlanner.Agents.Packs.Calendars"]

      assert forbidden_references(
               Code.string_to_quoted!(~s|GtfsPlanner.Gtfs.Calendars.get_calendar(a, b, c)|)
             ) == ["GtfsPlanner.Gtfs.Calendars"]

      assert forbidden_references(Code.string_to_quoted!(~s|alias GtfsPlanner.Agents.EchoPack|)) ==
               ["GtfsPlanner.Agents.EchoPack"]
    end
  end

  defp active_scope do
    organization = organization_fixture()
    user = user_fixture()
    organization_membership_fixture(user, organization)
    scope_fixture(organization, user)
  end

  defp scope_fixture(organization, user) do
    version = gtfs_version_fixture(organization.id)

    %Scope{
      organization_id: organization.id,
      gtfs_version_id: version.id,
      user_id: user.id,
      user_email: user.email,
      pack_id: "echo",
      version_name: version.name
    }
  end

  defp echo_arguments_of_size(size) when size >= byte_size(~s|{"text":""}|) do
    ~s|{"text":"| <> String.duplicate("a", size - byte_size(~s|{"text":""}|)) <> ~s|"}|
  end

  defp read_source(path) do
    File.cwd!()
    |> Path.join(path)
    |> File.read!()
    |> Code.string_to_quoted!()
  end

  defp forbidden_references(ast) do
    {_ast, found} =
      Macro.prewalk(ast, [], fn
        {:__aliases__, _meta, parts} = node, found when is_list(parts) ->
          if Enum.any?(@forbidden_prefixes, &List.starts_with?(parts, &1)) do
            {node, [Enum.join(parts, ".") | found]}
          else
            {node, found}
          end

        node, found ->
          {node, found}
      end)

    found |> Enum.uniq() |> Enum.sort()
  end
end
