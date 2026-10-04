defmodule GtfsPlannerWeb.Gtfs.StopTextHelperLiveTest do
  @moduledoc """
  Merge evidence (EV-23) for the Stop text helper on the real stops catalog.

  The page, its session and the turn task are separate processes, so the SQL sandbox
  and the `Req.Test` plug are shared (`async: false`) and only the provider's HTTP
  boundary is scripted. The approved set is made through the page's own form events,
  and the helper is opened through its own `agent_open` event, so a missing binding
  fails the case. The stops are `S410`, `S500` and `S600` from the approval fixture.
  """

  use GtfsPlannerWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures
  import GtfsPlannerWeb.HeadsignHelperLiveHelpers, only: [assigns: 1, eventually: 1]
  import Phoenix.LiveViewTest

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Agents.ScriptedProvider
  alias GtfsPlanner.Gtfs.Stop
  alias GtfsPlanner.Repo

  setup %{conn: conn} do
    Req.Test.set_req_test_to_shared()
    ScriptedProvider.track_sessions()

    organization = organization_fixture()
    user = user_fixture()

    {:ok, membership} =
      Accounts.create_user_org_membership(%{
        user_id: user.id,
        organization_id: organization.id,
        roles: ["pathways_studio_editor"]
      })

    version = gtfs_version_fixture(organization.id)

    stops =
      for {stop_id, name} <- [
            {"S410", "Elm Street Station"},
            {"S500", "Pine Plaza"},
            {"S600", "Main St @ Elm"}
          ],
          into: %{} do
        {stop_id, stop_fixture(organization.id, version.id, %{stop_id: stop_id, stop_name: name})}
      end

    %{
      conn: log_in_user(conn, user, organization: organization),
      membership: membership,
      version: version,
      stops: stops
    }
  end

  setup {Req.Test, :verify_on_exit!}

  describe "where the helper is offered and what it binds" do
    test "no approved set, no helper; approving one offers it and binds exactly those stops",
         context do
      view = open_catalog(context)
      refute has_element?(view, "#agent-helper-open")
      refute has_element?(view, "#agent-panel")
      assert assigns(view).agent_context.source_snapshot == nil

      approve(view, "S500\nS410")
      assert has_element?(view, "#agent-helper-open", "Open helper")
      refute has_element?(view, "#agent-panel")

      view |> element("#agent-helper-open") |> render_click()

      assert has_element?(view, "#agent-panel")
      assert has_element?(view, "#agent-panel", "Stop text helper")
      assert has_element?(view, "#agent-panel", "2 approved stops")

      assigns = assigns(view)
      assert is_pid(assigns.agent_session)
      assert assigns.agent_context.identity == {:version, context.version.id}

      # The UUIDs are sorted, whatever order the lines were typed in.
      assert %{kind: "stop_set", payload: payload} = assigns.agent_context.source_snapshot

      assert payload == %{
               "schema_version" => 1,
               "stop_uuids" => Enum.sort([context.stops["S410"].id, context.stops["S500"].id])
             }
    end

    test "a different set or a clear replaces the conversation; the same set changes nothing",
         context do
      view = open_catalog(context)
      approve(view, "S410\nS500")
      view |> element("#agent-helper-open") |> render_click()
      first = say(view, "How many stops are approved?", "Two stops are approved.")

      # Approving the identical set again keeps the conversation and its transcript.
      approve(view, "S500\nS410")
      same = assigns(view)
      assert same.agent_conversation_id == first.agent_conversation_id
      assert same.agent_entries_empty? == false
      refute has_element?(view, "#agent-notice")

      # A different set is a new conversation, and the panel says so.
      approve(view, "S410\nS500\nS600")
      second = assigns(view)
      assert second.agent_conversation_id != first.agent_conversation_id
      assert second.agent_entries_empty? == true
      assert has_element?(view, "#agent-panel", "3 approved stops")

      assert has_element?(
               view,
               "#agent-notice",
               "The stop list changed, so the helper started a new conversation."
             )

      # A clear hides the helper and binds the bare version context again.
      view |> element("#stop-set-clear") |> render_click()

      refute has_element?(view, "#agent-helper-open")
      refute has_element?(view, "#agent-panel")
      assert assigns(view).agent_open? == false
      assert assigns(view).agent_context.source_snapshot == nil

      # The next set starts closed rather than reopening the old panel.
      approve(view, "S410")
      refute has_element?(view, "#agent-panel")
      assert has_element?(view, "#agent-helper-open")
    end
  end

  describe "failures leave the catalog usable" do
    test "a deactivated membership opens to the forbidden notice", context do
      view = open_catalog(context)
      approve(view, "S410")
      deactivate_membership_fixture(context.membership)

      view |> element("#agent-helper-open") |> render_click()

      assert has_element?(view, "#agent-notice", "Your access changed.")
    end

    test "a stop deleted after approval opens to the unavailable notice", context do
      view = open_catalog(context)
      approve(view, "S410\nS500")
      stop_uuid = context.stops["S500"].id
      Repo.delete_all(from(s in Stop, where: s.id == ^stop_uuid))

      view |> element("#agent-helper-open") |> render_click()

      assert has_element?(view, "#agent-notice", "The helper is unavailable right now.")
    end

    test "with the provider failing, search, sort and paging still work and the set is kept",
         context do
      ScriptedProvider.stub_outage()

      view = open_catalog(context)
      approve(view, "S410\nS500")
      set = assigns(view).stop_set
      view |> element("#agent-helper-open") |> render_click()

      view
      |> element("#agent-composer")
      |> render_submit(%{"agent" => %{"message" => "Fix the names."}})

      eventually(fn -> assigns(view).agent_unavailable? end)

      view |> element("#stop-search-form") |> render_change(%{search: "Pine"})
      assert assigns(view).search == "Pine"

      render_hook(view, "sort", %{"key" => "stop_id"})
      assert assigns(view).sort_by == :stop_id

      render_hook(view, "paginate", %{"page" => "1"})
      assert assigns(view).page == 1

      assert has_element?(view, "#stops-count")
      assert has_element?(view, "#stop-set-summary", "2 stops approved")
      assert assigns(view).stop_set == set
    end
  end

  # -- helpers ----------------------------------------------------------------

  defp open_catalog(context) do
    {:ok, view, _html} = live(context.conn, ~p"/gtfs/#{context.version.id}/stops")
    view |> element("#stop-set-toggle") |> render_click()
    view
  end

  # The page's own approval: Find stops, then Approve stops.
  defp approve(view, text) do
    view |> form("#stop-set-form", stop_set: %{refs: text}) |> render_submit()
    view |> element("#stop-set-approve") |> render_click()
  end

  # One composer round trip with a scripted text reply; waits for the entry and returns
  # the page's assigns.
  defp say(view, text, reply) do
    ScriptedProvider.expect_reply(ScriptedProvider.text_reply(reply))
    view |> element("#agent-composer") |> render_submit(%{"agent" => %{"message" => text}})
    eventually(fn -> has_element?(view, "#agent-entries article", reply) end)
    assigns(view)
  end
end
