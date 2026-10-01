defmodule GtfsPlanner.Agents.SourceSnapshotTest do
  @moduledoc """
  The bounded immutable source snapshot every later timetable step admits (EV-1).

  A snapshot is copied into the conversation's own resource context by the host
  and read back by a pack tool; it is never persisted and never carried by model
  output. The four cases are the ones the step's execution card names:

    * `Agents.open/1` with `Scope.context/1` and the shipped Calendar pack, and an
      approval that keeps the semantics it already had without a snapshot;
    * the whole serialized resource context admitted at exactly 65,536 bytes and
      refused at 65,537, and a tampered envelope refused without attaching a
      session or disturbing the native input the person already typed;
    * distinct sessions for distinct payloads, and a context replacement that
      drops this panel's transcript while another tab keeps its own;
    * a revoked membership or a deleted, foreign or forged route refused at send,
      dispatch, delivery and prepared lookup, disclosing no foreign metadata.

  Every entry point is the shipped one — `Scope`, `GtfsPlanner.Agents`,
  `GtfsPlanner.Agents.Dispatch`, and `GtfsPlannerWeb.AgentPanel.set_context/2` on
  the socket the real Calendars page mounted. Only the final OpenRouter HTTP
  boundary is scripted (INV-5). The expected byte counts and digests are written
  out here from the card's description rather than read back from the module
  under test.
  """

  use GtfsPlannerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Agents
  alias GtfsPlanner.Agents.Dispatch
  alias GtfsPlanner.Agents.Packs.Calendars
  alias GtfsPlanner.Agents.Packs.ServiceQueries
  alias GtfsPlanner.Agents.Scope
  alias GtfsPlanner.Agents.TurnSupervisor
  alias GtfsPlanner.Repo
  alias GtfsPlannerWeb.AgentPanel

  # The test environment routes `GtfsPlanner.Agents.Model` through this plug, so
  # every scripted response below replaces only the OpenRouter HTTP boundary.
  @owner GtfsPlanner.Agents.Model
  @model "test/model-a"

  @max_context_bytes 65_536
  @approval_text "Extend the weekday calendar through the fall term."
  @forbidden_text "Your access changed. The helper stopped."

  @kind "timetable"
  @prepare_arguments ~s|{"dates":["2026-10-05","2026-10-06"],"stop":["SCHOOL_WD"],"run":[]}|

  setup {Req.Test, :verify_on_exit!}

  setup do
    # The turn task is not in this process's callers, so the Req.Test plug and
    # the SQL sandbox must both be shared.
    Req.Test.set_req_test_to_shared()
    ensure_turn_supervisor()

    organization = organization_fixture()
    user = user_fixture()
    membership = organization_membership_fixture(user, organization)
    version = gtfs_version_fixture(organization.id, %{name: "Snapshot Version"})

    add_calendar(organization, version, "SCHOOL_WD", "School weekdays")
    add_calendar(organization, version, "SCHOOL_EX", "School express")

    track_sessions()

    %{organization: organization, user: user, membership: membership, version: version}
  end

  describe "opening a conversation that carries no source" do
    test "the Calendar pack opens from a plain context and another person never reaches it",
         context do
      scope = scope(context, Scope.context({:version, context.version.id}))

      assert Scope.authorized_context(scope) == :ok
      assert Scope.source_snapshot(scope) == nil
      assert Scope.approved_digest(scope) == "none"

      assert {:ok, pid, snapshot} = Agents.open(scope)
      assert is_pid(pid)
      assert snapshot.entries == []

      # The same context is the same conversation, in this tab and any other.
      assert {:ok, ^pid, _same} = Agents.open(scope)

      assert {:ok, _other, _other_snapshot} =
               Agents.open(%{scope | user_id: Ecto.UUID.generate()})
    end

    test "an approval keeps its own digest, and a source changes only the conversation key",
         context do
      approved = scope(context, approved_context(context))

      assert Scope.authorized_context(approved) == :ok
      assert Scope.source_snapshot(approved) == nil
      assert byte_size(Scope.approved_digest(approved)) == 64
      assert Scope.approved_digest(approved) != "none"

      # The same approval built again hashes the same, a different one does not,
      # and no approval at all is "none".
      assert Scope.approved_digest(approved) ==
               Scope.approved_digest(scope(context, approved_context(context)))

      assert Scope.approved_digest(approved) !=
               Scope.approved_digest(scope(context, plain_context(context)))

      assert Scope.approved_digest(approved) !=
               Scope.approved_digest(
                 scope(
                   context,
                   %{
                     approved_context(context)
                     | approved_extension: %{
                         approved_extension()
                         | end_date: ~D[2027-02-28]
                       }
                   }
                 )
               )

      with_source = %{approved | resource_context: admitted(context, %{"rows" => []})}

      assert Scope.approved_digest(with_source) == Scope.approved_digest(approved)
      assert Scope.context_digest(with_source) != Scope.context_digest(approved)

      assert {:ok, pid, _approved_snapshot} = Agents.open(approved)
      assert {:ok, other, _other_snapshot} = Agents.open(with_source)
      assert other != pid
    end

    test "the two-key context the Calendars page builds itself carries no source", context do
      # `CalendarsLive.approve_extension/2` builds this map itself, with the two
      # keys that existed before snapshots did.
      legacy = %{
        identity: {:version, context.version.id},
        approved_extension: approved_extension()
      }

      scope = scope(context, legacy)

      assert Scope.authorized_context(scope) == :ok
      assert Scope.source_snapshot(scope) == nil
      assert byte_size(Scope.context_digest(scope)) == 64
      assert {:ok, pid, _snapshot} = Agents.open(scope)
      assert is_pid(pid)
    end
  end

  describe "admitting a source" do
    test "a whole context of exactly 65,536 bytes is admitted and 65,537 is refused", context do
      context_map = approved_context(context)

      at_the_limit = snapshot_of_bytes(context_map, @max_context_bytes)

      assert {:ok, admitted_context} = Scope.with_source_snapshot(context_map, at_the_limit)
      assert serialized_bytes(context_map, admitted_context.source_snapshot) == @max_context_bytes

      scope = scope(context, admitted_context)

      assert %{kind: @kind, payload: payload, digest: digest} = Scope.source_snapshot(scope)
      assert digest == server_digest(@kind, payload)

      assert Scope.authorized_context(scope) == :ok
      assert {:ok, pid, _snapshot} = Agents.open(scope)
      assert is_pid(pid)

      # One byte more is refused, and the caller's context is returned untouched.
      over_the_limit = snapshot_of_bytes(context_map, @max_context_bytes + 1)
      measured_over = Scope.with_source_snapshot(context_map, over_the_limit)

      assert measured_over == {:error, :too_large}
      assert context_map == approved_context(context)
    end

    test "a caller-hashed envelope, an unknown kind and a non-JSON payload are refused",
         context do
      context_map = approved_context(context)
      valid = snapshot(%{"rows" => [%{"text" => "Mon 07:10 to Main St"}]})

      assert Scope.with_source_snapshot(context_map, Map.put(valid, :digest, digest_stub())) ==
               {:error, :invalid_snapshot}

      assert Scope.with_source_snapshot(context_map, Map.put(valid, :label, "extra")) ==
               {:error, :invalid_snapshot}

      assert Scope.with_source_snapshot(context_map, %{kind: "  ", payload: %{}}) ==
               {:error, :invalid_snapshot}

      assert Scope.with_source_snapshot(context_map, %{
               kind: String.duplicate("k", 65),
               payload: %{}
             }) ==
               {:error, :invalid_snapshot}

      assert Scope.with_source_snapshot(context_map, %{
               kind: @kind,
               payload: %{"at" => ~D[2026-10-05]}
             }) ==
               {:error, :invalid_snapshot}

      # A finite number is a JSON value; a date, an atom and a non-string key
      # are not.
      assert {:ok, admitted_float} =
               Scope.with_source_snapshot(context_map, %{kind: @kind, payload: %{"at" => 1.5}})

      assert Scope.source_snapshot(scope(context, admitted_float)).payload == %{"at" => 1.5}

      assert Scope.with_source_snapshot(context_map, %{kind: @kind, payload: %{"at" => :now}}) ==
               {:error, :invalid_snapshot}

      assert Scope.with_source_snapshot(context_map, %{
               kind: @kind,
               payload: %{"at" => %{1 => "one"}}
             }) ==
               {:error, :invalid_snapshot}

      assert Scope.with_source_snapshot(context_map, %{
               kind: @kind,
               payload: [%{"text" => "a row"}]
             }) ==
               {:error, :invalid_snapshot}

      assert Scope.with_source_snapshot(context_map, %{kind: @kind, payload: "07:10"}) ==
               {:error, :invalid_snapshot}

      assert Scope.with_source_snapshot(context_map, %{kind: @kind}) ==
               {:error, :invalid_snapshot}

      assert Scope.with_source_snapshot(context_map, "not a snapshot") ==
               {:error, :invalid_snapshot}
    end

    test "a tampered, replaced or oversized envelope never attaches a session or clears native input",
         context do
      {view, _pid} = open_panel(context)

      # The person has approved an extension through the native form on this
      # page, and the page's own copy of that decision is what the panel holds.
      view
      |> element("#calendar-extension-form")
      |> render_submit(%{
        "extension" => %{
          "service_id" => "SCHOOL_WD",
          "end_date" => "2027-01-30",
          "approval_text" => @approval_text
        }
      })

      assert render(view) =~ @approval_text
      assert Scope.source_snapshot(scope(context, panel_context(view))) == nil

      before = session_pids()
      admitted_context = admitted(context, %{"rows" => []})
      envelope = admitted_context.source_snapshot

      # A digest that does not hash the content beside it.
      forged = envelope |> Map.put(:digest, digest_stub())
      # The same content under a kind the server never hashed with it.
      relabelled = Map.put(envelope, :kind, "approved_table")
      # The same envelope with its payload swapped for another one.
      swapped = Map.put(envelope, :payload, %{"rows" => [%{"text" => "someone else's table"}]})
      # A correctly hashed envelope that is simply too large: the same context
      # without it authorizes, so only the size can be refusing it.
      big_payload = %{"rows" => [%{"text" => String.duplicate("x", 70_000)}]}
      oversized = %{kind: @kind, payload: big_payload, digest: server_digest(@kind, big_payload)}

      for tampered_snapshot <- [forged, relabelled, swapped, oversized] do
        tampered =
          scope(context, Map.put(approved_context(context), :source_snapshot, tampered_snapshot))

        assert Scope.authorized_context(tampered) == {:error, :unavailable}
        assert Agents.open(tampered) == {:error, :unavailable}
      end

      assert Scope.authorized_context(
               scope(context, Map.put(approved_context(context), :source_snapshot, nil))
             ) == :ok

      # No refused envelope started or joined a session.
      assert session_pids() -- before == []

      # The panel never adopted one either, and the person's own input is exactly
      # where they left it.
      assert Scope.source_snapshot(scope(context, panel_context(view))) == nil
      assert render(view) =~ @approval_text
      assert has_element?(view, "#calendar-extension-approve")
    end
  end

  describe "one conversation per source" do
    test "two payloads are two conversations and one payload is shared", context do
      first = scope(context, admitted(context, %{"rows" => [%{"text" => "Mon 07:10"}]}))
      second = scope(context, admitted(context, %{"rows" => [%{"text" => "Tue 08:25"}]}))
      third = scope(context, admitted(context, %{"rows" => [%{"text" => "Mon 07:10"}]}))

      assert {:ok, first_pid, _first_snapshot} = Agents.open(first)
      assert {:ok, second_pid, _second_snapshot} = Agents.open(second)
      assert {:ok, third_pid, _third_snapshot} = Agents.open(third)

      assert first_pid != second_pid
      assert first_pid != third_pid
    end

    test "a replaced source drops this panel's transcript and its late results, and leaves another tab's alone",
         context do
      {view, original} = open_panel(context)

      # A second tab on the same page, holding the same context.
      {second_tab, _same_pid} = open_panel(context)
      assert session_pid(second_tab) == original

      expect_reply(text_reply("The copied table runs weekdays."))

      view
      |> element("#agent-composer")
      |> render_submit(%{"agent" => %{"message" => "What does the table say?"}})

      assert await_settled(original).text == "The copied table runs weekdays."
      assert has_element?(view, "#agent-entry-2")
      assert has_element?(second_tab, "#agent-entry-2")

      # The host attaches a source and replaces the context, exactly as it does
      # for a route identity: the shipped panel function on this page's socket.
      replace_context(view, admitted(context, %{"rows" => [%{"text" => "Mon 07:10"}]}))

      assert Scope.source_snapshot(scope(context, panel_context(view))).kind == @kind
      assert session_pid(view) != original
      assert panel_assigns(view).agent_entries_empty?

      refute has_element?(view, "#agent-entry-2")
      assert has_element?(view, "#agent-first-conversation")

      # A late entry and a late down from the replaced session cannot restore it.
      send(view.pid, {:agent_event, original, {:entry, entry(2, "A late answer.")}})
      send(view.pid, {:DOWN, make_ref(), :process, original, :normal})
      render(view)

      refute has_element?(view, "#agent-entry-2")
      refute render(view) =~ "A late answer."
      assert session_pid(view) != original

      # The other tab was never detached and keeps its own conversation.
      assert Process.alive?(original)
      assert session_pid(second_tab) == original
      assert has_element?(second_tab, "#agent-entry-2")

      # The page's own replacement, the one it performs when the person approves
      # an extension, drops the source the panel was holding as well.
      view
      |> element("#calendar-extension-form")
      |> render_submit(%{
        "extension" => %{
          "service_id" => "SCHOOL_WD",
          "end_date" => "2027-01-30",
          "approval_text" => @approval_text
        }
      })

      replaced = panel_context(view)
      assert Scope.source_snapshot(scope(context, replaced)) == nil
      assert replaced.approved_extension.service_id == "SCHOOL_WD"
      assert replaced.approved_extension.approval_text == @approval_text
      refute has_element?(view, "#agent-entry-2")
    end
  end

  describe "the boundaries a withdrawn or gone context must stop" do
    test "a revoked editor stops the conversation at send, delivery and prepared lookup",
         context do
      {view, pid} = open_panel(context)
      # A second conversation on the same page, opened under the page's own
      # approval so it is a different conversation from the panel's.
      replying = scope(context, approved_context(context))
      assert {:ok, replying_pid, _snapshot} = Agents.open(replying)
      refute replying_pid == pid

      expect_reply(calls_reply([{"call_1", "prepare_date_change", @prepare_arguments}], 0.0001))

      # The membership is withdrawn between the tool result and the answer, so
      # the turn's own delivery check is the one that refuses.
      expect_reply_deactivating(context, text_reply("SHOULD-NOT-APPEAR", 0.0002))

      replying_monitor = Process.monitor(replying_pid)
      monitor = Process.monitor(pid)

      view
      |> element("#agent-composer")
      |> render_submit(%{"agent" => %{"message" => "No school service on October 5 and 6."}})

      assert_receive {:agent_event, ^pid,
                      {:entry, %{role: :assistant, status: :forbidden} = entry}},
                     5_000

      assert entry.text == @forbidden_text
      assert entry.prepared == nil
      refute_received {:agent_event, ^pid, {:entry, %{text: "SHOULD-NOT-APPEAR"}}}
      assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}, 2_000

      # The prepared lookup is the first boundary the withdrawn editor reaches on
      # the second conversation, and it refuses before the proposal is read: the
      # session goes down with it rather than waiting for a send.
      assert Agents.prepared(replying_pid, "a-conversation", 1) == :error
      assert_receive {:DOWN, ^replying_monitor, :process, ^replying_pid, :normal}, 2_000

      # The send on that same conversation is refused too, as is the answer that
      # was already in flight for the first one.
      assert Agents.send_message(replying_pid, "One more question?") == {:error, :ended}
      assert Agents.send_message(pid, "A later question?") == {:error, :ended}
      assert Agents.prepared(pid, "a-conversation", 2) == :error

      # Dispatch and a new attachment refuse the same conversation, and the
      # refusal carries no organization, version or route of its own.
      assert Dispatch.call(Calendars, plain_scope(context), "list_calendars", "{}") ==
               {:error, :forbidden}

      assert Agents.open(plain_scope(context)) == {:error, :forbidden}
      assert render(view) =~ @forbidden_text
    end

    test "a deleted, foreign or forged route refuses the route-bound pack at dispatch", context do
      route = route_fixture(context.organization.id, context.version.id)
      other_version = gtfs_version_fixture(context.organization.id)
      other_version_route = route_fixture(context.organization.id, other_version.id)

      foreign_organization = organization_fixture()
      foreign_version = gtfs_version_fixture(foreign_organization.id)
      foreign_route = route_fixture(foreign_organization.id, foreign_version.id)

      arguments = ~s|{"service_date":"2026-10-05"}|
      bound = route_scope(context, route.id)

      assert {:ok, _result} =
               Dispatch.call(ServiceQueries, bound, "list_boarding_occurrences", arguments)

      Repo.delete!(route)

      assert Dispatch.call(ServiceQueries, bound, "list_boarding_occurrences", arguments) ==
               {:error, :unavailable}

      # Another version, another organization, a deleted id and a malformed one
      # are one result, so no foreign metadata is disclosed.
      for id <- [
            other_version_route.id,
            foreign_route.id,
            Ecto.UUID.generate(),
            "not-a-uuid"
          ] do
        forged = route_scope(context, id)

        assert Dispatch.call(ServiceQueries, forged, "list_boarding_occurrences", arguments) ==
                 {:error, :unavailable}
      end
    end
  end

  ## Helpers

  # The Calendars page with its helper panel open. The test process joins the
  # conversation as a second listener, so the session's own settle events are
  # observable without polling the render or sleeping.
  defp open_panel(context) do
    conn = log_in_user(context.conn, context.user, organization: context.organization)
    assert {:ok, view, _html} = live(conn, "/gtfs/#{context.version.id}/calendars")
    assert has_element?(view, "#agent-helper-open")

    view |> element("#agent-helper-open") |> render_click()
    assert has_element?(view, "#agent-panel")

    pid = session_pid(view)
    assert is_pid(pid)
    assert {:ok, ^pid, _snapshot} = Agents.open(plain_scope(context))

    {view, pid}
  end

  # The host's own production call, run against this page's mounted socket. The
  # panel function is the shipped one, so the replacement this performs is the
  # one any host performs when the conversation's context changes.
  defp replace_context(view, context) do
    :sys.replace_state(view.pid, fn state ->
      %{state | socket: AgentPanel.set_context(state.socket, context)}
    end)

    _ = :sys.get_state(view.pid)
    :ok
  end

  defp plain_scope(context), do: scope(context, Scope.context({:version, context.version.id}))

  defp route_scope(context, route_id) do
    scope(context, Scope.context({:route, route_id}), "service_queries")
  end

  defp scope(context, resource_context, pack_id \\ "calendars") do
    %Scope{
      organization_id: context.organization.id,
      gtfs_version_id: context.version.id,
      user_id: context.user.id,
      user_email: context.user.email,
      pack_id: pack_id,
      version_name: context.version.name,
      resource_context: resource_context
    }
  end

  defp panel_context(view), do: panel_assigns(view).agent_context

  defp panel_assigns(view), do: :sys.get_state(view.pid).socket.assigns

  defp session_pid(view), do: panel_assigns(view).agent_session

  # The approval the Calendars LiveView copies into the panel context when the
  # native form is submitted.
  defp approved_extension do
    %{service_id: "SCHOOL_WD", end_date: ~D[2027-01-30], approval_text: @approval_text}
  end

  defp plain_context(context) do
    %{identity: {:version, context.version.id}, approved_extension: nil}
  end

  defp approved_context(context) do
    %{identity: {:version, context.version.id}, approved_extension: approved_extension()}
  end

  defp snapshot(payload), do: %{kind: @kind, payload: payload}

  defp admitted(context, payload) do
    assert {:ok, admitted} =
             Scope.with_source_snapshot(approved_context(context), snapshot(payload))

    admitted
  end

  # A payload whose whole serialized context is exactly `target` bytes. The
  # filler absorbs the difference, so the expected size is a written-out number
  # rather than whatever the module under test happens to produce.
  defp snapshot_of_bytes(context, target) do
    empty = %{"rows" => [%{"text" => ""}]}

    envelope = %{
      kind: @kind,
      payload: empty,
      digest: server_digest(@kind, empty)
    }

    filler = target - serialized_bytes(context, envelope)

    if filler < 0, do: raise("a #{target}-byte context cannot hold this envelope")

    snapshot(%{"rows" => [%{"text" => String.duplicate("x", filler)}]})
  end

  # The measurement the card describes, written out here: one JSON object
  # holding the tagged identity, the approval with ISO dates, and the snapshot
  # envelope with its digest.
  defp serialized_bytes(context, snapshot) do
    Jason.encode!(%{
      "identity" => tagged_identity(context[:identity]),
      "approved_extension" => tagged_approved(context[:approved_extension]),
      "source_snapshot" => tagged_snapshot(snapshot)
    })
    |> byte_size()
  end

  defp tagged_identity({kind, id}), do: %{"kind" => Atom.to_string(kind), "id" => id}
  defp tagged_identity(_other), do: nil

  defp tagged_approved(%{service_id: id, end_date: date, approval_text: text}),
    do: %{"service_id" => id, "end_date" => Date.to_iso8601(date), "approval_text" => text}

  defp tagged_approved(_other), do: nil

  defp tagged_snapshot(%{kind: kind, payload: payload, digest: digest}),
    do: %{"kind" => kind, "payload" => payload, "digest" => digest}

  defp tagged_snapshot(_other), do: nil

  # Lowercase SHA-256 of the server's own deterministic term encoding.
  defp server_digest(kind, payload) do
    {kind, payload}
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  # A well-formed 64-character lowercase digest that hashes nothing here.
  defp digest_stub, do: "a" <> String.duplicate("0", 63)

  defp entry(id, text) do
    %{
      id: id,
      role: :assistant,
      text: text,
      activity: [],
      prepared: nil,
      evidence: [],
      applied?: false,
      status: :done
    }
  end

  defp await_settled(pid) do
    assert_receive {:agent_event, ^pid, {:entry, %{role: :assistant} = entry}}, 5_000

    if entry.status == :working, do: await_settled(pid), else: entry
  end

  defp add_calendar(organization, version, service_id, name) do
    weekdays = %{
      monday: 1,
      tuesday: 1,
      wednesday: 1,
      thursday: 1,
      friday: 1,
      saturday: 0,
      sunday: 0
    }

    calendar_fixture(organization.id, version.id, Map.put(weekdays, :service_id, service_id))

    calendar_attribute_fixture(organization.id, version.id, %{
      service_id: service_id,
      service_description: name
    })
  end

  defp ensure_turn_supervisor do
    if is_nil(Process.whereis(TurnSupervisor)) do
      start_supervised!({Task.Supervisor, name: TurnSupervisor, max_children: 8})
    end
  end

  # Sessions are started under the application's own supervisor and outlive the
  # test socket, so every session this test opened is terminated here.
  defp track_sessions do
    before = session_pids()

    on_exit(fn ->
      for pid <- session_pids(), pid not in before do
        DynamicSupervisor.terminate_child(GtfsPlanner.Agents.SessionSupervisor, pid)
      end
    end)
  end

  defp session_pids do
    GtfsPlanner.Agents.SessionSupervisor
    |> DynamicSupervisor.which_children()
    |> Enum.map(fn {_id, pid, _type, _modules} -> pid end)
  end

  ## Scripted OpenRouter replies

  defp expect_reply(payload, count \\ 1) do
    test = self()
    Req.Test.expect(@owner, count, fn conn -> respond(conn, test, payload) end)
  end

  # Answers with `payload` after withdrawing the membership, so the turn's own
  # next authorization check sees the revocation.
  defp expect_reply_deactivating(context, payload) do
    test = self()

    Req.Test.expect(@owner, 1, fn conn ->
      deactivate_membership_fixture(context.membership)
      respond(conn, test, payload)
    end)
  end

  defp respond(conn, test, payload) do
    {:ok, body, conn} = Plug.Conn.read_body(conn)
    send(test, {:model_request, Jason.decode!(body)})

    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(200, Jason.encode!(payload))
  end

  defp text_reply(text, cost \\ 0.0), do: reply("stop", %{"content" => text}, cost)

  defp calls_reply(calls, cost) do
    tool_calls =
      Enum.map(calls, fn {id, name, arguments} ->
        %{
          "id" => id,
          "type" => "function",
          "function" => %{"name" => name, "arguments" => arguments}
        }
      end)

    reply("tool_calls", %{"content" => nil, "tool_calls" => tool_calls}, cost)
  end

  defp reply(finish_reason, message, cost) do
    %{
      "model" => @model,
      "choices" => [%{"finish_reason" => finish_reason, "message" => message}],
      "usage" => %{"cost" => cost}
    }
  end
end
