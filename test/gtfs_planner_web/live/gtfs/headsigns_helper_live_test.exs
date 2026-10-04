defmodule GtfsPlannerWeb.Gtfs.HeadsignsHelperLiveTest do
  @moduledoc """
  Merge evidence (EV-4) for the Headsign helper on the real pattern page.

  The page, its session and the turn task are separate processes, so the SQL
  sandbox and the `Req.Test` plug are shared (`async: false`) and only the
  provider's HTTP boundary is scripted. Nothing here assigns `agent_context`,
  `agent_session` or `agent_conversation_id` by hand: the helper is opened through
  the page's own `agent_open` event, so a missing binding fails the case. The A01
  fixture is `GtfsPlanner.HeadsignHelperFixtures`.
  """

  use GtfsPlannerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.HeadsignHelperFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Agents.ScriptedProvider
  alias GtfsPlanner.Gtfs.RoutePattern
  alias GtfsPlanner.Repo

  setup %{conn: conn} do
    Req.Test.set_req_test_to_shared()
    ScriptedProvider.track_sessions()

    organization = organization_fixture()
    user = user_fixture()

    {:ok, membership} =
      GtfsPlanner.Accounts.create_user_org_membership(%{
        user_id: user.id,
        organization_id: organization.id,
        roles: ["pathways_studio_editor"]
      })

    version = gtfs_version_fixture(organization.id)
    a01 = a01_fixture(organization.id, version.id)
    conn = log_in_user(conn, user, organization: organization)

    %{
      conn: conn,
      user: user,
      membership: membership,
      organization: organization,
      version: version,
      a01: a01
    }
  end

  setup {Req.Test, :verify_on_exit!}

  describe "where the helper is offered and what it binds" do
    test "Details offers the helper and an opened session is bound to the pattern", context do
      {:ok, view, _html} = live(context.conn, pattern_path(context, "?task=details"))

      assert has_element?(view, "#agent-helper-open", "Open helper")
      refute has_element?(view, "#agent-panel")

      view |> element("#agent-helper-open") |> render_click()
      assert has_element?(view, "#agent-panel")
      assert has_element?(view, "#agent-panel", "Pattern Downtown · Details")

      assigns = assigns(view)
      assert is_pid(assigns.agent_session)
      assert assigns.agent_context.identity == {:route, context.a01.route.id}

      assert %{kind: "headsign_scope", payload: payload} = assigns.agent_context.source_snapshot

      assert payload == %{
               "schema_version" => 1,
               "pattern_id" => context.a01.pattern.id,
               "timing_id" => nil
             }
    end

    test "the Stops task, the patterns list and a new pattern offer no helper", context do
      {:ok, view, _html} = live(context.conn, pattern_path(context, "?task=stops"))
      refute has_element?(view, "#agent-helper-open")

      {:ok, view, _html} =
        live(context.conn, "/gtfs/#{context.version.id}/routes/R1/patterns")

      refute has_element?(view, "#agent-helper-open")

      {:ok, view, _html} =
        live(context.conn, "/gtfs/#{context.version.id}/routes/R1/patterns/new")

      refute has_element?(view, "#agent-helper-open")
    end

    test "Running times binds the selected timing", context do
      {:ok, view, _html} =
        live(context.conn, pattern_path(context, "?task=timings&timing=#{context.a01.peak.id}"))

      view |> element("#agent-helper-open") |> render_click()

      assert has_element?(view, "#agent-panel", "Pattern Downtown · Running times · Peak")

      assert %{payload: %{"timing_id" => timing_id}} = assigns(view).agent_context.source_snapshot
      assert timing_id == context.a01.peak.id
    end

    test "a new timing, or a new task, starts a new conversation and leaves native state alone",
         context do
      {:ok, view, _html} =
        live(
          context.conn,
          pattern_path(context, "?task=timings&timing=#{context.a01.off_peak.id}")
        )

      view |> element("#agent-helper-open") |> render_click()
      first = say(view, "Which trips follow the default?", "Summarized.")

      before = native_state(view)
      assert first.agent_entries_empty? == false

      # Another timing is another target.
      render_hook(view, "select_timing", %{"timing_id" => context.a01.peak.id})
      second = assigns(view)

      assert second.agent_context.source_snapshot.payload["timing_id"] == context.a01.peak.id
      assert second.agent_conversation_id != first.agent_conversation_id
      assert second.agent_entries_empty? == true
      assert native_state(view) == before

      # So is another task of the same pattern.
      third = say(view, "And these?", "Summarized again.")

      view |> element("#pattern-task-details") |> render_click()
      fourth = assigns(view)

      assert fourth.agent_context.source_snapshot.payload["timing_id"] == nil
      assert fourth.agent_conversation_id != third.agent_conversation_id
      assert fourth.agent_entries_empty? == true
      assert has_element?(view, "#agent-panel")

      assert native_state(view) |> Map.take([:timing_edits, :timing_headsign_edits, :dirty?]) ==
               Map.take(before, [:timing_edits, :timing_headsign_edits, :dirty?])
    end
  end

  describe "failures leave the native page usable" do
    test "a deactivated membership opens to the forbidden notice", context do
      {:ok, view, _html} = live(context.conn, pattern_path(context, "?task=details"))
      deactivate_membership_fixture(context.membership)

      view |> element("#agent-helper-open") |> render_click()

      assert has_element?(view, "#agent-panel")
      assert has_element?(view, "#agent-notice", "Your access changed.")
    end

    test "a pattern deleted under the page opens to the unavailable notice", context do
      gone =
        route_pattern_fixture(context.organization.id, context.version.id, %{
          route_id: "R1",
          route_pattern_id: "A01-GONE",
          route_pattern_name: "Gone"
        })

      {:ok, view, _html} =
        live(context.conn, pattern_path(context, "A01-GONE", "?task=details"))

      assert has_element?(view, "#agent-helper-open")
      Repo.delete!(gone)

      view |> element("#agent-helper-open") |> render_click()

      assert has_element?(view, "#agent-notice", "The helper is unavailable right now.")
    end

    test "with the provider failing, the Details form still saves a name change", context do
      ScriptedProvider.stub_outage()

      {:ok, view, _html} = live(context.conn, pattern_path(context, "?task=details"))
      view |> element("#agent-helper-open") |> render_click()

      view
      |> element("#agent-composer")
      |> render_submit(%{"agent" => %{"message" => "Which trips follow the default?"}})

      assert_eventually(fn -> assigns(view).agent_unavailable? end)

      view
      |> element("#pattern-details-form")
      |> render_submit(%{
        "pattern" => %{
          "name" => "Downtown Loop",
          "direction_id" => "0",
          "headsign" => "Downtown Terminal",
          "time_desc" => "",
          "typicality" => "0",
          "sort_order" => "0"
        }
      })

      assert Repo.get!(RoutePattern, context.a01.pattern.id).route_pattern_name == "Downtown Loop"
    end
  end

  describe "the prepared card" do
    test "renders Review headsigns and the stub refuses without raising", context do
      {:ok, view, _html} = live(context.conn, pattern_path(context, "?task=details"))
      view |> element("#agent-helper-open") |> render_click()

      ScriptedProvider.expect_tool_turn(
        "prepare_headsign_change",
        ~s({"current_text":"Downtown Terminal","new_text":"Central Station"}),
        "I prepared the rename."
      )

      view
      |> element("#agent-composer")
      |> render_submit(%{
        "agent" => %{"message" => "Rename Downtown Terminal to Central Station"}
      })

      assert_eventually(fn -> has_element?(view, "[id^='agent-review-prepared-']") end)

      assert has_element?(view, "[id^='agent-review-prepared-']", "Review headsigns")

      view |> element("[id^='agent-review-prepared-']") |> render_click()

      assert has_element?(view, "#agent-notice", "Review is not ready on this page yet.")
      assert Repo.get!(RoutePattern, context.a01.pattern.id).headsign == "Downtown Terminal"
    end
  end

  # -- helpers ----------------------------------------------------------------

  defp pattern_path(context, query),
    do: pattern_path(context, context.a01.pattern.route_pattern_id, query)

  defp pattern_path(context, route_pattern_id, query),
    do: "/gtfs/#{context.version.id}/routes/R1/patterns/#{route_pattern_id}#{query}"

  defp assigns(view), do: :sys.get_state(view.pid).socket.assigns

  defp native_state(view),
    do: Map.take(assigns(view), [:details_form, :timing_edits, :timing_headsign_edits, :dirty?])

  # Sends one message through the composer with a scripted text reply and waits for
  # the entry to settle, returning the page's assigns.
  defp say(view, text, reply) do
    ScriptedProvider.expect_reply(ScriptedProvider.text_reply(reply))

    view |> element("#agent-composer") |> render_submit(%{"agent" => %{"message" => text}})
    assert_eventually(fn -> has_element?(view, "#agent-entries article", reply) end)

    assigns(view)
  end

  # The session's events reach the page asynchronously; poll the rendered page
  # rather than sleeping a fixed time.
  defp assert_eventually(fun, attempts \\ 100) do
    cond do
      fun.() -> :ok
      attempts == 0 -> flunk("condition not reached")
      true -> Process.sleep(50) && assert_eventually(fun, attempts - 1)
    end
  end
end
