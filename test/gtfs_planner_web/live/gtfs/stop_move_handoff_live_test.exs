defmodule GtfsPlannerWeb.Gtfs.StopMoveHandoffLiveTest do
  @moduledoc """
  Merge evidence (EV-20) for the `Review move` handoff on the real stops map.

  A prepared card is produced by the real session with only the provider's HTTP
  boundary scripted, and street routing is faked at its HTTP boundary with a counter,
  so the native move review the card starts is the production one. Pressing the card
  starts that review and nothing else: the stop row, its update stamp and the audit
  log do not change until the editor's own Apply.
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
  alias GtfsPlanner.Gtfs.ChangeLog
  alias GtfsPlanner.Gtfs.Stop
  alias GtfsPlanner.Repo

  @routing_owner GtfsPlanner.StreetRouting.Geoapify

  setup :set_mox_global

  setup %{conn: conn} do
    Req.Test.set_req_test_to_shared(%{})
    ScriptedProvider.track_sessions()

    original_key = Application.get_env(:gtfs_planner, :geoapify_api_key)
    Application.put_env(:gtfs_planner, :geoapify_api_key, "test-move-handoff-key-17ab")

    on_exit(fn ->
      if is_nil(original_key),
        do: Application.delete_env(:gtfs_planner, :geoapify_api_key),
        else: Application.put_env(:gtfs_planner, :geoapify_api_key, original_key)

      Req.Test.set_req_test_to_private(%{})
    end)

    organization = organization_fixture()
    user = user_fixture()

    {:ok, _membership} =
      Accounts.create_user_org_membership(%{
        user_id: user.id,
        organization_id: organization.id,
        roles: ["pathways_studio_editor"]
      })

    version = gtfs_version_fixture(organization.id)
    %{stops: stops} = staged_move_fixture(organization, version)
    conn = log_in_user(conn, user, organization: organization)

    %{conn: conn, organization: organization, version: version, stops: stops}
  end

  setup {Req.Test, :verify_on_exit!}

  test "Review move starts the native review without saving anything", context do
    counter = counting_routing_stub()
    {view, entry} = prepared_view(context)
    before = {stop_stamps(context), audit_count(context)}
    assert :counters.get(counter, 1) == 0

    view |> element("#agent-review-prepared-#{entry}") |> render_click()
    settle(view)

    assert has_element?(view, "#stops-map-move-panel")
    # The review's own routing request happened after the press, not before.
    assert :counters.get(counter, 1) >= 1
    assert {stop_stamps(context), audit_count(context)} == before
    assert assigns(view).agent_notice == nil
  end

  test "closing the native review returns focus to the card that started it", context do
    stub_routing()
    {view, entry} = prepared_view(context)

    view |> element("#agent-review-prepared-#{entry}") |> render_click()
    settle(view)
    view |> element("#stops-map-move-back") |> render_click()

    card_id = "agent-prepared-#{entry}"
    assert_push_event(view, "agent:focus", %{id: ^card_id})
    assert has_element?(view, "##{card_id}")

    # The target is spent: a second Back, or a review the editor starts, has no card to
    # return to.
    assert assigns(view).move_return_focus == nil
  end

  test "each refusal changes nothing and says why", context do
    stub_routing()

    # Another stop is selected after the card was prepared: the helper's conversation
    # was replaced, so the stored entry is no longer current.
    {view, entry} = prepared_view(context)
    close_edit_panel(view)
    render_hook(view, "select_stop", %{"stop_id" => "1330"})
    settle(view)
    refused(view, entry, "no longer current", context)

    # The edit panel is closed.
    {view, entry} = prepared_view(context)
    close_edit_panel(view)
    refused(view, entry, "no longer current", context)

    # A review is already showing: a second press is refused until the editor is done.
    {view, entry} = prepared_view(context)
    view |> element("#agent-review-prepared-#{entry}") |> render_click()
    settle(view)
    assert has_element?(view, "#stops-map-move-panel")
    refused(view, entry, "already open", context, review?: true)
  end

  test "a card pressed behind the delete or replace panel is refused and starts no review",
       context do
    counter = counting_routing_stub()

    for action <- ["delete", "replace"] do
      {view, entry} = prepared_view(context, "&action=#{action}")
      assert has_element?(view, "#stops-map-#{action}-panel")

      refused(view, entry, "Another panel is open", context)
      assert has_element?(view, "#stops-map-#{action}-panel")
      assert assigns(view).move_loading? == false
    end

    assert :counters.get(counter, 1) == 0
  end

  test "a card whose point no longer equals the draft is refused", context do
    stub_routing()
    {view, entry} = prepared_view(context)

    # Typing different coordinates replaces the conversation; reading the old entry
    # through the same session shows the stored command no longer matches the draft.
    %{"lat" => lat} = assigns(view).agent_context.source_snapshot.payload["candidate"]
    {lon2, lat2} = north(staged_lat(), 30.0)

    view
    |> form("#stops-map-edit-form", %{
      "stop" => %{"stop_lat" => "#{lat2}", "stop_lon" => "#{lon2}"}
    })
    |> render_change()

    refute assigns(view).agent_context.source_snapshot.payload["candidate"]["lat"] == lat
    refused(view, entry, "no longer current", context)
  end

  test "starting to add a stop closes the helper and the old card starts no review", context do
    counter = counting_routing_stub()
    {view, entry} = prepared_view(context)
    assert has_element?(view, "#stops-map-helper")

    view |> element("#stops-map-add-stop") |> render_click()

    assert has_element?(view, "#stops-map-add-panel")
    refute has_element?(view, "#stops-map-helper")
    refute has_element?(view, "#agent-panel")
    assert assigns(view).agent_open? == false
    assert assigns(view).agent_context.source_snapshot == nil

    # A press that arrives anyway (a stale click, a forged event) reaches no review.
    render_hook(view, "agent_review_prepared", %{"entry" => Integer.to_string(entry)})
    settle(view)

    assert :counters.get(counter, 1) == 0
    assert {assigns(view).move_loading?, assigns(view).move_review} == {false, nil}
  end

  test "a forged, foreign or missing entry does nothing and does not raise", context do
    stub_routing()
    {:ok, view, _html} = live(context.conn, "/gtfs/#{context.version.id}/stops/map?stop=1434")
    settle(view)
    before = {stop_stamps(context), audit_count(context)}

    # No session yet.
    render_hook(view, "agent_review_prepared", %{"entry" => "2"})
    refute has_element?(view, "#stops-map-move-panel")

    view |> element("#agent-helper-open") |> render_click()

    for forged <- [%{"entry" => "999"}, %{"entry" => "abc"}, %{"entry" => 2}, %{}] do
      render_hook(view, "agent_review_prepared", forged)
      refute has_element?(view, "#stops-map-move-panel")
    end

    assert {stop_stamps(context), audit_count(context)} == before
  end

  test "the native Apply saves the move and the helper starts a fresh conversation", context do
    stub_routing()
    {view, entry} = prepared_view(context)
    before = assigns(view).agent_conversation_id

    view |> element("#agent-review-prepared-#{entry}") |> render_click()
    settle(view)
    view |> element("#stops-map-move-save") |> render_click()
    settle(view)

    assert has_element?(view, "#stops-map-move-saved-message")
    saved = Repo.get!(Stop, context.stops["1434"].id)
    {_lon, lat} = north(staged_lat(), 13.7)
    assert_in_delta Decimal.to_float(saved.stop_lat), lat, 0.00001
    assert audit_count(context) >= 1

    after_apply = assigns(view)
    assert after_apply.agent_conversation_id != before
    assert after_apply.agent_entries_empty? == true
    refute has_element?(view, "[id^='agent-prepared-']")
    assert after_apply.agent_context.source_snapshot.payload["candidate"] == nil
  end

  test "delete and replace stay native actions with the helper open", context do
    stub_routing()
    {view, _entry} = prepared_view(context)
    render_hook(view, "cancel_edit", %{})

    {:ok, view, _html} =
      live(context.conn, "/gtfs/#{context.version.id}/stops/map?stop=1434&action=delete")

    settle(view)
    view |> element("#agent-helper-open") |> render_click()

    assert has_element?(view, "#stops-map-delete-panel")
    assert has_element?(view, "#agent-panel")

    refute Enum.any?(
             GtfsPlanner.Agents.Packs.StopImpact.tools(),
             &(&1.name =~ ~r/delete|replace/)
           )
  end

  # -- helpers ----------------------------------------------------------------

  # Selects stop 1434, places the pin 13.7 m north, opens the helper and prepares the
  # move through the scripted provider; returns the view and the prepared entry's id.
  defp prepared_view(context, query \\ "") do
    {:ok, view, _html} =
      live(context.conn, "/gtfs/#{context.version.id}/stops/map?stop=1434#{query}")

    settle(view)
    Mox.stub(GeocodingMock, :autocomplete, fn _text, _opts -> {:ok, []} end)
    Mox.allow(GeocodingMock, self(), view.pid)

    {lon, lat} = north(staged_lat(), 13.7)
    render_hook(view, "pin_moved", %{"lat" => lat, "lon" => lon})

    view |> element("#agent-helper-open") |> render_click()
    ScriptedProvider.expect_tool_turn("prepare_stop_move", "{}", "I prepared the move.")

    view
    |> element("#agent-composer")
    |> render_submit(%{"agent" => %{"message" => "Keep the stop and prepare the move."}})

    {view, await_prepared_entry(view)}
  end

  # Putting the pin back leaves the draft clean, so the edit panel closes at once instead
  # of asking about unsaved changes.
  defp close_edit_panel(view) do
    render_hook(view, "put_back", %{})
    render_hook(view, "cancel_edit", %{})
  end

  defp await_prepared_entry(view, attempts \\ 100) do
    case Regex.run(~r/id="agent-review-prepared-(\d+)"/, render(view)) do
      [_match, id] ->
        String.to_integer(id)

      nil when attempts > 0 ->
        Process.sleep(50)
        await_prepared_entry(view, attempts - 1)

      nil ->
        flunk("the prepared card never appeared")
    end
  end

  # Presses the card's entry and asserts the refusal: a notice, and no write and no new
  # native review (unless one was already showing).
  defp refused(view, entry, notice, context, opts \\ []) do
    before = {stop_stamps(context), audit_count(context)}
    move_state = Map.take(assigns(view), [:move_loading?, :move_saving?, :move_review])

    render_hook(view, "agent_review_prepared", %{"entry" => Integer.to_string(entry)})
    settle(view)

    # With the edit panel closed the helper is hidden, so the notice is read from the page.
    assert assigns(view).agent_notice =~ notice
    assert {stop_stamps(context), audit_count(context)} == before

    if opts[:review?] do
      assert Map.take(assigns(view), [:move_loading?, :move_saving?, :move_review]) == move_state
    else
      refute has_element?(view, "#stops-map-move-panel")
    end
  end

  defp settle(view, rounds \\ 8)
  defp settle(view, 0), do: view

  defp settle(view, rounds) do
    render_async(view, 5_000)
    settle(view, rounds - 1)
  end

  defp assigns(view), do: :sys.get_state(view.pid).socket.assigns

  defp stop_stamps(context) do
    Repo.all(
      from(s in Stop,
        where: s.organization_id == ^context.organization.id,
        order_by: s.id,
        select: {s.id, s.updated_at, s.stop_lat, s.stop_lon}
      )
    )
  end

  defp audit_count(context),
    do:
      Repo.aggregate(
        from(l in ChangeLog, where: l.organization_id == ^context.organization.id),
        :count
      )

  defp counting_routing_stub do
    counter = :counters.new(1, [])

    Req.Test.stub(@routing_owner, fn conn ->
      :counters.add(counter, 1, 1)
      routing_response(conn)
    end)

    counter
  end

  defp stub_routing, do: Req.Test.stub(@routing_owner, &routing_response/1)

  defp routing_response(conn) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(
      200,
      Jason.encode!(%{
        "type" => "FeatureCollection",
        "features" => [
          %{
            "type" => "Feature",
            "properties" => %{"mode" => "bus"},
            "geometry" => %{
              "type" => "MultiLineString",
              "coordinates" => [[[-124.0530, 44.6205], [-124.0530, 44.6215]]]
            }
          }
        ]
      })
    )
  end
end
