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
            "window" => %{
              "type" => "object",
              "properties" => %{
                "mode" => %{"type" => "string", "maxLength" => 10},
                "count" => %{"type" => "integer", "minimum" => 1, "maximum" => 5},
                "exact" => %{"type" => "boolean"}
              },
              "required" => ["mode"],
              "additionalProperties" => false
            },
            "stops" => %{
              "type" => "array",
              "items" => %{
                "type" => "object",
                "properties" => %{
                  "stop_id" => %{"type" => "string"},
                  "sequence" => %{"type" => "integer", "minimum" => 1, "maximum" => 20}
                },
                "required" => ["stop_id"],
                "additionalProperties" => false
              },
              "maxItems" => 2
            },
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
      },
      %{
        name: "evidenced",
        description: "Returns server evidence beside its result.",
        activity: "Evidenced a read",
        parameters: %{
          "type" => "object",
          "properties" => %{"bytes" => %{"type" => "integer", "minimum" => 0}},
          "required" => ["bytes"],
          "additionalProperties" => false
        }
      },
      %{
        name: "evidenced_prepare",
        description: "Returns a prepared change that carries its own evidence.",
        activity: "Prepared evidence",
        parameters: %{
          "type" => "object",
          "properties" => %{"bytes" => %{"type" => "integer", "minimum" => 0}},
          "required" => ["bytes"],
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

  def call("evidenced", %{"bytes" => bytes}, %Scope{}) do
    notify("evidenced")
    {:ok, %{"count" => bytes}, evidence(bytes)}
  end

  def call("evidenced_prepare", %{"bytes" => bytes}, %Scope{}) do
    notify("evidenced_prepare")

    prepared = %{
      summary: %{title: "Probe change", detail: "1 date", lines: ["Probe · 1 date"]},
      command: {:probe_change, bytes},
      evidence: evidence(bytes)
    }

    {:prepared, prepared, %{"count" => bytes}}
  end

  # A digest-sized string, so a test can put the evidence either side of the
  # shared byte limit without inventing a second bound.
  defp evidence(bytes) do
    %{
      kind: "probe",
      title: "Probe",
      total: bytes,
      total_label: "rows",
      completeness: :complete,
      completeness_reason: nil,
      facts: [],
      source_ref: "probe_source",
      digest: String.duplicate("a", bytes),
      source_revision: nil,
      scope: %{organization_id: nil, gtfs_version_id: nil, identity: nil},
      exclusions: [],
      resources: [%{kind: "probe", id: "probe-1", label: "Probe one"}]
    }
  end

  # `Dispatch.call/4` runs in the test process, so `self/0` is the test's mailbox.
  defp notify(name), do: send(self(), {:probe_pack_called, name})
end

defmodule GtfsPlanner.Agents.DispatchTest.UnsupportedPack do
  @moduledoc """
  Test-only pack declaring schema constraints outside the fence's subset.

  A pack is code-owned, so a keyword the fence does not implement is a defect to
  raise about: enforcing only part of `pattern` would let the model exceed it.
  """

  @behaviour GtfsPlanner.Agents.Pack

  alias GtfsPlanner.Agents.Scope

  @impl true
  def id, do: "unsupported"

  @impl true
  def title, do: "Unsupported helper"

  @impl true
  def intro, do: "Declares an unsupported constraint."

  @impl true
  def examples, do: ["Probe the fence"]

  @impl true
  def skill, do: "Declares an unsupported constraint."

  @impl true
  def tools do
    [
      %{
        name: "patterned",
        description: "Declares a pattern the fence does not implement.",
        activity: "Probed a pattern",
        parameters: %{
          "type" => "object",
          "properties" => %{"code" => %{"type" => "string", "pattern" => "^[A-Z]+$"}},
          "required" => ["code"],
          "additionalProperties" => false
        }
      }
    ]
  end

  @impl true
  def call("patterned", _args, %Scope{}), do: {:ok, %{}}
end

defmodule GtfsPlanner.Agents.DispatchTest do
  use GtfsPlanner.DataCase, async: false

  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Agents.Dispatch
  alias GtfsPlanner.Agents.DispatchTest.ProbePack
  alias GtfsPlanner.Agents.DispatchTest.UnsupportedPack
  alias GtfsPlanner.Agents.EchoPack
  alias GtfsPlanner.Agents.Scope

  # EchoPack plus every pack the application ships, so the fence covers the registry.
  @packs [EchoPack | Map.values(GtfsPlanner.Agents.packs())]

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

      # The cap counts characters, so 100 two-byte characters stay within it.
      multibyte = String.duplicate("é", 100)

      assert {:ok, %{"query" => ^multibyte}} =
               Dispatch.call(ProbePack, scope, "probe", Jason.encode!(%{"query" => multibyte}))

      assert_received {:probe_pack_called, "probe"}
    end

    test "enforces array item types and item counts" do
      scope = active_scope()

      assert Dispatch.call(ProbePack, scope, "probe", ~s|{"query":"ok","dates":[1,2]}|) ==
               {:tool_error, "Argument dates[0] must be a string."}

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

    test "validates a nested object against its own declared keys and bounds" do
      scope = active_scope()

      assert Dispatch.call(ProbePack, scope, "probe", ~s|{"query":"ok","window":{"mode":1}}|) ==
               {:tool_error, "Argument window.mode must be a string."}

      assert Dispatch.call(ProbePack, scope, "probe", ~s|{"query":"ok","window":{"mode":null}}|) ==
               {:tool_error, "Argument window.mode must not be null."}

      assert Dispatch.call(ProbePack, scope, "probe", ~s|{"query":"ok","window":{"count":2}}|) ==
               {:tool_error, "Missing required argument: window.mode"}

      assert Dispatch.call(
               ProbePack,
               scope,
               "probe",
               ~s|{"query":"ok","window":{"mode":"ok","organization_id":"org"}}|
             ) == {:tool_error, "Unexpected argument: window.organization_id"}

      assert Dispatch.call(
               ProbePack,
               scope,
               "probe",
               ~s|{"query":"ok","window":{"mode":"ok","exact":"yes"}}|
             ) == {:tool_error, "Argument window.exact must be true or false."}

      refute_received {:probe_pack_called, _}
    end

    test "enforces nested integer and string limits at the nesting depth" do
      scope = active_scope()

      assert Dispatch.call(
               ProbePack,
               scope,
               "probe",
               ~s|{"query":"ok","window":{"mode":"ok","count":6}}|
             ) == {:tool_error, "Argument window.count must be at most 5."}

      assert Dispatch.call(
               ProbePack,
               scope,
               "probe",
               ~s|{"query":"ok","window":{"mode":"ok","count":0}}|
             ) == {:tool_error, "Argument window.count must be at least 1."}

      assert Dispatch.call(
               ProbePack,
               scope,
               "probe",
               ~s|{"query":"ok","window":{"mode":"abcdefghijk"}}|
             ) == {:tool_error, "Argument window.mode must be at most 10 characters."}

      refute_received {:probe_pack_called, _}
    end

    test "validates array items against their own object schema" do
      scope = active_scope()

      assert Dispatch.call(
               ProbePack,
               scope,
               "probe",
               ~s|{"query":"ok","stops":[{"stop_id":"a","sequence":21}]}|
             ) == {:tool_error, "Argument stops[0].sequence must be at most 20."}

      assert Dispatch.call(ProbePack, scope, "probe", ~s|{"query":"ok","stops":[{"sequence":1}]}|) ==
               {:tool_error, "Missing required argument: stops[0].stop_id"}

      assert Dispatch.call(
               ProbePack,
               scope,
               "probe",
               ~s|{"query":"ok","stops":[{"stop_id":"a","user_id":"user"}]}|
             ) == {:tool_error, "Unexpected argument: stops[0].user_id"}

      assert Dispatch.call(
               ProbePack,
               scope,
               "probe",
               ~s|{"query":"ok","stops":[{"stop_id":"a"},{"stop_id":"b"},{"stop_id":"c"}]}|
             ) == {:tool_error, "Argument stops must have 2 or fewer items."}

      refute_received {:probe_pack_called, _}
    end

    test "accepts nested arguments exactly at their declared bounds" do
      scope = active_scope()

      arguments =
        Jason.encode!(%{
          "query" => "ok",
          "window" => %{"mode" => "abcdefghij", "count" => 5, "exact" => true},
          "stops" => [
            %{"stop_id" => "a", "sequence" => 1},
            %{"stop_id" => "b", "sequence" => 20}
          ]
        })

      assert {:ok, _result} = Dispatch.call(ProbePack, scope, "probe", arguments)
      assert_received {:probe_pack_called, "probe"}
    end

    test "raises on a declared constraint the fence does not implement" do
      scope = active_scope()

      assert_raise ArgumentError, ~r/unsupported JSON Schema keyword pattern/, fn ->
        Dispatch.call(UnsupportedPack, scope, "patterned", ~s|{"code":"ABC"}|)
      end
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

  describe "server evidence" do
    test "returns the pack's evidence beside its result" do
      scope = active_scope()

      assert {:ok, %{"count" => 3}, evidence} =
               Dispatch.call(ProbePack, scope, "evidenced", ~s|{"bytes":3}|)

      assert evidence.kind == "probe"
      assert evidence.total == 3
      assert evidence.source_ref == "probe_source"
      assert evidence.resources == [%{kind: "probe", id: "probe-1", label: "Probe one"}]

      assert_received {:probe_pack_called, "evidenced"}
    end

    test "refuses a result and evidence over the byte limit together and without truncating" do
      scope = active_scope()

      assert Dispatch.call(ProbePack, scope, "evidenced", ~s|{"bytes":#{@result_cap}}|) ==
               {:tool_error, "Too much data for one result. Narrow the request."}

      # The pack ran, so the refusal is the fence's byte accounting and not a
      # failure to reach the tool at all.
      assert_received {:probe_pack_called, "evidenced"}
    end

    test "lifts a prepared result's own evidence into the same transport" do
      scope = active_scope()

      assert {:prepared, %{summary: %{title: "Probe change"}, command: {:probe_change, 4}},
              %{"count" => 4}, evidence} =
               Dispatch.call(ProbePack, scope, "evidenced_prepare", ~s|{"bytes":4}|)

      assert evidence.total == 4
      assert_received {:probe_pack_called, "evidenced_prepare"}
    end

    test "accepts the old two-element result form unchanged" do
      scope = active_scope()

      assert {:ok, %{"query" => "ok"}} =
               Dispatch.call(ProbePack, scope, "probe", ~s|{"query":"ok"}|)

      assert_received {:probe_pack_called, "probe"}
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
