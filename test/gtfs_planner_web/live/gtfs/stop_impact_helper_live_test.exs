defmodule GtfsPlannerWeb.Gtfs.StopImpactHelperLiveTest do
  @moduledoc """
  Merge evidence (EV-18) for the Stop impact helper on the real stops map.

  The page, its session and the turn task are separate processes, so the SQL sandbox
  and the `Req.Test` plug are shared (`async: false`) and only the provider's HTTP
  boundary is scripted. Nothing here assigns `agent_context` or `agent_session` by
  hand: the helper is opened through the page's own `agent_open` event, so a missing
  binding fails the case. The stop is `1434` from `GtfsPlanner.StopHelperFixtures`.
  """

  use GtfsPlannerWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import Mox, only: [set_mox_global: 1]
  import Phoenix.LiveViewTest
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.StopHelperFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Agents.ScriptedProvider
  alias GtfsPlanner.GeocodingMock
  alias GtfsPlanner.Gtfs.Stop
  alias GtfsPlanner.Repo

  setup :set_mox_global

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
    %{stops: stops} = staged_move_fixture(organization, version)
    conn = log_in_user(conn, user, organization: organization)

    %{
      conn: conn,
      organization: organization,
      membership: membership,
      version: version,
      stops: stops
    }
  end

  setup {Req.Test, :verify_on_exit!}

  describe "where the helper is offered and what it binds" do
    test "no stop, no helper; an open stop offers it and binds that stop with no pin", context do
      view = open_map(context, "")
      refute has_element?(view, "#agent-helper-open")
      refute has_element?(view, "#agent-panel")

      view = open_map(context, "?stop=1434")
      assert has_element?(view, "#agent-helper-open", "Open helper")
      refute has_element?(view, "#agent-panel")

      view |> element("#agent-helper-open") |> render_click()
      assert has_element?(view, "#agent-panel")
      assert has_element?(view, "#agent-panel", "Stop 1434")

      assigns = assigns(view)
      assert is_pid(assigns.agent_session)
      assert assigns.agent_context.identity == {:version, context.version.id}

      assert %{kind: "stop_focus", payload: payload} = assigns.agent_context.source_snapshot

      assert payload == %{
               "schema_version" => 1,
               "stop_uuid" => context.stops["1434"].id,
               "candidate" => nil
             }

      # Closing the edit panel removes the button, the panel and the binding.
      render_hook(view, "cancel_edit", %{})
      refute has_element?(view, "#agent-helper-open")
      refute has_element?(view, "#agent-panel")
      assert assigns(view).agent_context.source_snapshot == nil
      assert assigns(view).agent_open? == false
    end

    test "a moved pin or typed coordinates start a new conversation and leave the edit alone",
         context do
      view = open_map(context, "?stop=1434")
      view |> element("#agent-helper-open") |> render_click()
      first = say(view, "What uses this stop?", "It is used by one pattern.")

      view
      |> form("#stops-map-edit-form", %{"stop" => %{"stop_name" => "Renamed"}})
      |> render_change()

      before = edit_state(view)
      {lon, lat} = north(staged_lat(), 13.7)
      render_hook(view, "pin_moved", %{"lat" => lat, "lon" => lon})

      second = assigns(view)

      # The pin is the page's own draft point, which the page rounds to five decimals.
      assert second.agent_context.source_snapshot.payload["candidate"] ==
               %{"lat" => Float.round(lat, 5), "lon" => Float.round(lon, 5)}

      assert second.agent_conversation_id != first.agent_conversation_id
      assert second.agent_entries_empty? == true

      assert has_element?(
               view,
               "#agent-notice",
               "The pin moved, so the helper started a new conversation."
             )

      # The helper changed no native state: the typed name survives and the draft
      # differs from before only by the coordinates the pin wrote.
      after_state = edit_state(view)
      assert after_state.edit_draft["stop_name"] == "Renamed"

      assert Map.drop(after_state.edit_draft, ["stop_lat", "stop_lon"]) ==
               Map.drop(before.edit_draft, ["stop_lat", "stop_lon"])

      assert after_state.edit_dirty? == true
      assert after_state.edit_move.lat == Float.round(lat, 5)

      # Typing a coordinate is the same kind of move.
      {lon2, lat2} = north(staged_lat(), 30.0)

      view
      |> form("#stops-map-edit-form", %{
        "stop" => %{"stop_lat" => "#{lat2}", "stop_lon" => "#{lon2}"}
      })
      |> render_change()

      third = assigns(view)
      assert third.agent_conversation_id != second.agent_conversation_id

      assert third.agent_context.source_snapshot.payload["candidate"]["lat"] == lat2
    end

    test "a saved correction ends the pin's conversation and the page's pending move",
         context do
      view = open_map(context, "?stop=1434")
      view |> element("#agent-helper-open") |> render_click()

      # Within the 8 m correction band, so the form saves without a move review.
      {lon, lat} = north(staged_lat(), 1.5)
      render_hook(view, "pin_moved", %{"lat" => lat, "lon" => lon})
      moved = assigns(view)
      assert moved.agent_context.source_snapshot.payload["candidate"] != nil
      assert has_element?(view, "#agent-panel", "pin placed")

      view |> form("#stops-map-edit-form") |> render_submit()
      settle(view)

      saved = assigns(view)
      assert saved.edit_move == nil
      assert saved.agent_context.source_snapshot.payload["candidate"] == nil
      assert saved.agent_conversation_id != moved.agent_conversation_id
      refute has_element?(view, "#agent-panel", "pin placed")
      refute has_element?(view, "#stops-map-edit-moved")
    end

    test "putting the pin back, or choosing another stop, rebinds without a pin notice",
         context do
      view = open_map(context, "?stop=1434")
      view |> element("#agent-helper-open") |> render_click()

      {lon, lat} = north(staged_lat(), 13.7)
      render_hook(view, "pin_moved", %{"lat" => lat, "lon" => lon})
      assert assigns(view).agent_context.source_snapshot.payload["candidate"] != nil

      render_hook(view, "put_back", %{})
      assert assigns(view).agent_context.source_snapshot.payload["candidate"] == nil

      # Another stop is another conversation, and the pin notice is not shown for it.
      before = assigns(view).agent_conversation_id

      render_hook(view, "cancel_edit", %{})
      render_hook(view, "select_stop", %{"stop_id" => "1330"})
      settle(view)
      view |> element("#agent-helper-open") |> render_click()

      assigns = assigns(view)

      assert assigns.agent_context.source_snapshot.payload["stop_uuid"] ==
               context.stops["1330"].id

      assert assigns.agent_conversation_id != before
      refute has_element?(view, "#agent-notice", "The pin moved")
    end
  end

  describe "failures leave the native page usable" do
    test "a deactivated membership opens to the forbidden notice", context do
      view = open_map(context, "?stop=1434")
      deactivate_membership_fixture(context.membership)

      view |> element("#agent-helper-open") |> render_click()

      assert has_element?(view, "#agent-notice", "Your access changed.")
    end

    test "a stop deleted under the page opens to the unavailable notice", context do
      view = open_map(context, "?stop=1434")
      stop_uuid = context.stops["1434"].id
      Repo.delete_all(from(s in Stop, where: s.id == ^stop_uuid))

      view |> element("#agent-helper-open") |> render_click()

      assert has_element?(view, "#agent-notice", "The helper is unavailable right now.")
    end

    test "with the provider failing, the edit form still saves a name change", context do
      ScriptedProvider.stub_outage()

      view = open_map(context, "?stop=1434")
      view |> element("#agent-helper-open") |> render_click()

      view
      |> element("#agent-composer")
      |> render_submit(%{"agent" => %{"message" => "What uses this stop?"}})

      eventually(fn -> assigns(view).agent_unavailable? end)

      view
      |> form("#stops-map-edit-form", %{"stop" => %{"stop_name" => "Renamed Main St"}})
      |> render_submit()

      settle(view)
      assert Repo.get!(Stop, context.stops["1434"].id).stop_name == "Renamed Main St"
    end
  end

  describe "evidence" do
    test "a dependency answer links its stop to the stop's detail page", context do
      view = open_map(context, "?stop=1434")
      view |> element("#agent-helper-open") |> render_click()

      ScriptedProvider.expect_tool_turn(
        "get_stop_dependencies",
        "{}",
        "It is used by one pattern."
      )

      view
      |> element("#agent-composer")
      |> render_submit(%{"agent" => %{"message" => "What uses this stop?"}})

      selector = ~s(#agent-evidence-2-1 a[href="/gtfs/#{context.version.id}/stops/1434"])
      eventually(fn -> has_element?(view, selector) end)
      assert has_element?(view, "#agent-evidence-2-1", "rows that name this stop")
    end
  end

  # -- helpers ----------------------------------------------------------------

  defp open_map(context, query) do
    {:ok, view, _html} = live(context.conn, "/gtfs/#{context.version.id}/stops/map#{query}")
    settle(view)

    Mox.stub(GeocodingMock, :autocomplete, fn _text, _opts -> {:ok, []} end)
    Mox.allow(GeocodingMock, self(), view.pid)
    view
  end

  defp settle(view, rounds \\ 8)
  defp settle(view, 0), do: view

  defp settle(view, rounds) do
    render_async(view, 5_000)
    settle(view, rounds - 1)
  end

  defp assigns(view), do: :sys.get_state(view.pid).socket.assigns

  defp edit_state(view),
    do: Map.take(assigns(view), [:edit_draft, :edit_dirty?, :edit_move, :move_review])

  # One composer round trip with a scripted text reply; waits for the entry and returns
  # the page's assigns.
  defp say(view, text, reply) do
    ScriptedProvider.expect_reply(ScriptedProvider.text_reply(reply))
    view |> element("#agent-composer") |> render_submit(%{"agent" => %{"message" => text}})
    eventually(fn -> has_element?(view, "#agent-entries article", reply) end)
    assigns(view)
  end

  defp eventually(fun, attempts \\ 100) do
    cond do
      fun.() -> :ok
      attempts == 0 -> flunk("condition not reached")
      true -> Process.sleep(50) && eventually(fun, attempts - 1)
    end
  end
end
