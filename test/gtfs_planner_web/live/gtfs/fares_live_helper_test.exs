defmodule GtfsPlannerWeb.Gtfs.FaresLiveHelperTest do
  @moduledoc """
  Merge evidence (EV-9) for the Fare zones page's helper: the panel, the handoff of
  a prepared assignment into the page's own review and the confirmed save.

  The page, the conversation session and the turn task that prepares the
  assignment are separate processes, so the SQL sandbox and the `Req.Test` plug are
  shared (`async: false`) and only the OpenRouter HTTP boundary is scripted. Every
  expected zone and count is derived from `GtfsPlanner.FareSelectionFixtures`, and
  the rows a case claims were or were not written are read back from the database.
  """

  use GtfsPlannerWeb.ConnCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest
  import GtfsPlanner.AccountsFixtures

  import GtfsPlanner.Agents.PackTurn,
    only: [expect_reply: 1, setup_conversations: 0, text_reply: 1, tool_calls_reply: 1]

  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Agents
  alias GtfsPlanner.Agents.Scope
  alias GtfsPlanner.Gtfs.FareZones
  alias GtfsPlannerWeb.Gtfs.FaresComponents
  alias GtfsPlanner.FareSelectionFixtures
  alias GtfsPlanner.Gtfs.Stop
  alias GtfsPlanner.GtfsFixtures
  alias GtfsPlanner.Repo

  @prepare_arguments ~s({"route_ids":["R6"],"only_unzoned":true,"exclude_stop_ids":["AIR1"],"zone_id":"B"})

  @unavailable_notice "That prepared assignment is no longer available. Ask the helper again."
  @close_first_notice "Close the open review, drawer or dialog first, then review the assignment again."
  @selection_notice "Clear your selection first, or select exactly the prepared stops."
  @changed_notice "The routes' stops or zones changed after this was prepared. Ask the helper again."
  @edited_notice "Your edited assignment was saved. The original prepared assignment was not applied."
  @save_failed "Changes couldn’t be saved. Your edits are still here."

  setup {Req.Test, :verify_on_exit!}

  setup do
    setup_conversations()

    organization = organization_fixture()
    user = user_fixture()
    membership = organization_membership_fixture(user, organization)
    version = gtfs_version_fixture(organization.id, %{name: "Helper Zones Version"})

    stops = FareSelectionFixtures.insert_network!(organization, version)
    FareSelectionFixtures.declare_zone!(organization, version, "B")
    FareSelectionFixtures.declare_zone!(organization, version, "C")

    %{
      organization: organization,
      user: user,
      membership: membership,
      version: version,
      stops: stops
    }
  end

  describe "the panel" do
    test "Open helper renders the panel with the fare zone intro and examples", context do
      {:ok, view, _html} = open_zones(context)

      assert has_element?(view, "#agent-helper-open", "Open helper")
      refute has_element?(view, "#agent-panel")

      view |> element("#agent-helper-open") |> render_click()

      assert has_element?(view, "#agent-panel")
      assert has_element?(view, "#agent-helper-open[aria-expanded=true]")
      assert has_element?(view, "#agent-panel", "Fare zone helper")

      assert has_element?(
               view,
               "#agent-panel",
               "I can find stops by route, show their fare zones"
             )

      assert has_element?(view, "#agent-example-1", "Put unzoned Route 6 stops in Zone B")
      assert has_element?(view, "#agent-example-2", "Which Route 6 stops have no zone?")
      assert_push_event(view, "agent:focus", %{id: "agent-composer-input"})
    end

    test "the page's own controls still work with the panel open", context do
      {:ok, view, _html} = open_zones(context)
      view |> element("#agent-helper-open") |> render_click()

      view |> element("#fare-zone-create") |> render_click()
      assert has_element?(view, "#fare-zone-drawer")

      assert has_element?(view, "#fare-zone-row-all")
      assert has_element?(view, "#fare-zone-stage")
    end

    test "there is no helper button while the workspace loads or before the first zone",
         context do
      static =
        build_conn() |> log_in(context) |> get("/gtfs/#{context.version.id}/settings/fares/zones")

      refute html_response(static, 200) =~ "agent-helper-open"

      empty_version =
        gtfs_version_fixture(context.organization.id, %{name: "Empty Zones Version"})

      assert {:ok, view, _html} =
               build_conn()
               |> log_in(context)
               |> live("/gtfs/#{empty_version.id}/settings/fares/zones")

      assert has_element?(view, "#fare-zone-first-use")
      refute has_element?(view, "#agent-helper-open")
    end
  end

  describe "the handoff into the assignment review" do
    test "a prepared turn writes nothing, and Review opens the review on exactly the prepared stops",
         context do
      before = zones()
      {view, _pid} = prepared_view(context)

      assert has_element?(view, "#agent-review-prepared-2")
      refute has_element?(view, "#fare-zone-assignment-dialog")
      assert zones() == before

      view |> element("#agent-review-prepared-2") |> render_click()

      assert has_element?(view, "#fare-zone-assignment-dialog")
      assert has_element?(view, "#fare-zone-assignment-row-1", "Alder")
      assert has_element?(view, "#fare-zone-assignment-row-2", "Cedar")
      refute has_element?(view, "#fare-zone-assignment-row-3")
      review = view |> element("#fare-zone-assignment-rows") |> render()
      refute review =~ "Birch"
      refute review =~ "Airport Gate"
      assert has_element?(view, "#fare-zone-assignment-target option[selected][value=B]")
      assert has_element?(view, "#fare-zone-selection-count", "2 stops selected")
      assert zones() == before

      assert %{origin: %{entry_id: 2, return_focus_id: "agent-prepared-2"}} =
               assigns(view).assignment
    end

    test "a different manual selection keeps its work and gets the literal notice", context do
      {view, _pid} = prepared_view(context)

      render_click(view, "toggle_stop", %{"id" => context.stops["AIR2"].id})
      view |> element("#agent-review-prepared-2") |> render_click()

      refute has_element?(view, "#fare-zone-assignment-dialog")
      assert has_element?(view, "#fare-zone-selection-count", "1 stop selected")
      assert has_element?(view, "#agent-panel", @selection_notice)
    end

    test "the prepared set already selected opens the review", context do
      {view, _pid} = prepared_view(context)

      render_click(view, "toggle_stop", %{"id" => context.stops["A1"].id})
      render_click(view, "toggle_stop", %{"id" => context.stops["A3"].id})
      view |> element("#agent-review-prepared-2") |> render_click()

      assert has_element?(view, "#fare-zone-assignment-dialog")
      assert has_element?(view, "#fare-zone-selection-count", "2 stops selected")
    end

    test "an open review or an open drawer is never replaced", context do
      {view, _pid} = prepared_view(context)

      render_click(view, "toggle_stop", %{"id" => context.stops["AIR2"].id})
      view |> element("#fare-zone-assign-selection") |> render_click()
      assert has_element?(view, "#fare-zone-assignment-dialog")

      view |> element("#agent-review-prepared-2") |> render_click()

      assert has_element?(view, "#agent-panel", @close_first_notice)
      assert assigns(view).assignment.origin == nil
      assert has_element?(view, "#fare-zone-assignment-row-1", "Airport Terminal")

      view |> element("#fare-zone-assignment-dialog-cancel") |> render_click()
      refute has_element?(view, "#fare-zone-assignment-dialog")

      render_click(view, "clear_selection", %{})
      view |> element("#fare-zone-create") |> render_click()
      assert has_element?(view, "#fare-zone-drawer")

      view |> element("#agent-review-prepared-2") |> render_click()

      assert has_element?(view, "#agent-panel", @close_first_notice)
      refute has_element?(view, "#fare-zone-assignment-dialog")
    end

    test "a delete dialog is never replaced", context do
      {view, _pid} = prepared_view(context)

      render_click(view, "open_delete_zone", %{"zone_id" => "C"})
      assert assigns(view).zone_delete

      view |> element("#agent-review-prepared-2") |> render_click()

      assert has_element?(view, "#agent-panel", @close_first_notice)
      refute has_element?(view, "#fare-zone-assignment-dialog")
    end

    test "a forged, unknown or reset entry opens nothing and changes nothing", context do
      {view, pid} = prepared_view(context)
      before = zones()
      assert has_element?(view, "#agent-review-prepared-2")

      for id <- ["abc", "999", "-1", "0", "2.5", ""] do
        render_click(view, "agent_review_prepared", %{"entry" => id})

        assert has_element?(view, "#agent-panel", @unavailable_notice), "entry #{inspect(id)}"
        refute has_element?(view, "#fare-zone-assignment-dialog")
      end

      assert render_click(view, "agent_review_prepared", %{"entry" => 7}) =~ "agent-panel"
      refute has_element?(view, "#fare-zone-assignment-dialog")

      # An entry of the conversation that New conversation replaced is gone.
      view |> element("#agent-new-conversation") |> render_click()
      assert_receive {:agent_event, ^pid, {:reset, _conversation_id}}, 5_000
      render(view)

      render_click(view, "agent_review_prepared", %{"entry" => "2"})

      assert has_element?(view, "#agent-panel", @unavailable_notice)
      refute has_element?(view, "#fare-zone-assignment-dialog")
      assert zones() == before
    end

    test "a stop that joined the route after the preparation is a changed selection", context do
      {view, _pid} = prepared_view(context)

      GtfsFixtures.stop_time_fixture(context.organization.id, context.version.id, "T6", "U1", %{
        stop_sequence: 9
      })

      view |> element("#agent-review-prepared-2") |> render_click()

      assert has_element?(view, "#agent-panel", @changed_notice)
      refute has_element?(view, "#fare-zone-assignment-dialog")
      refute has_element?(view, "#fare-zone-selection-count")
    end

    test "a zone change on a stop of the route after the preparation is a changed selection",
         context do
      {view, _pid} = prepared_view(context)

      Repo.update_all(from(s in Stop, where: s.id == ^context.stops["A2"].id),
        set: [zone_id: nil]
      )

      view |> element("#agent-review-prepared-2") |> render_click()

      assert has_element?(view, "#agent-panel", @changed_notice)
      refute has_element?(view, "#fare-zone-assignment-dialog")
    end

    test "choosing another target in the open review keeps the origin", context do
      {view, _pid} = prepared_view(context)
      view |> element("#agent-review-prepared-2") |> render_click()

      view
      |> element("#fare-zone-assignment-target-form")
      |> render_change(%{"target" => "C"})

      assert has_element?(view, "#fare-zone-assignment-target option[selected][value=C]")
      assert %{origin: %{entry_id: 2}} = assigns(view).assignment
    end
  end

  describe "the helper-origin review" do
    test "shows the helper's summary, every row and each stop's other routes, with no Refresh",
         context do
      {view, _pid} = prepared_view(context)
      view |> element("#agent-review-prepared-2") |> render_click()

      helper = view |> element("#fare-zone-assignment-helper") |> render()

      for line <- [
            "Routes: 6",
            "Stops with no zone only",
            "2 gain a zone, 0 move from another zone, 0 already in Zone B",
            "Excluded: Airport Gate (AIR1)",
            "Also served by route 9 (1 stop)",
            "These zones export in the stops.txt zone column; fare rules keep their zone references."
          ] do
        assert helper =~ line
      end

      assert text_of(view, "#fare-zone-assignment-row-1") =~ "Alder"
      assert text_of(view, "#fare-zone-assignment-row-1-routes") == "No other routes"
      assert text_of(view, "#fare-zone-assignment-row-2-routes") == "9"
      assert has_element?(view, "#fare-zone-assignment-row-2", "Cedar")
      refute has_element?(view, "#fare-zone-assignment-refresh")
      refute has_element?(view, "#fare-zone-assignment-changed")
      assert has_element?(view, "#fare-zone-assignment-dialog-confirm", "Assign 2 stops")
    end

    test "lists all 150 stops of a large selection, while a manual review keeps 100 rows",
         context do
      GtfsFixtures.route_fixture(context.organization.id, context.version.id, %{route_id: "RBIG"})
      names = Enum.map(1..150, &"B#{String.pad_leading(Integer.to_string(&1), 3, "0")}")

      FareSelectionFixtures.insert_stops!(
        context.organization,
        context.version,
        Enum.map(names, &%{stop_id: &1, stop_name: "Big #{&1}"})
      )

      FareSelectionFixtures.call_at!(
        context.organization,
        context.version,
        "RBIG",
        "T-BIG",
        names
      )

      {view, _pid} =
        prepared_view(
          context,
          ~s({"route_ids":["RBIG"],"only_unzoned":true,"exclude_stop_ids":[],"zone_id":"C"})
        )

      view |> element("#agent-review-prepared-2") |> render_click()

      assert has_element?(view, "#fare-zone-assignment-row-150", "Big B150")
      refute has_element?(view, "#fare-zone-assignment-row-151")
      refute has_element?(view, "#fare-zone-assignment-more")

      view |> element("#fare-zone-assignment-dialog-cancel") |> render_click()
      render_click(view, "clear_selection", %{})

      ids =
        Repo.all(
          from(s in Stop, where: like(s.stop_id, "B1%") or like(s.stop_id, "B0%"), select: s.id)
        )

      assert length(ids) == 150
      render_click(view, "select_stops", %{"ids" => ids})
      view |> element("#fare-zone-assign-selection") |> render_click()

      assert has_element?(view, "#fare-zone-assignment-row-100")
      refute has_element?(view, "#fare-zone-assignment-row-101")
      assert text_of(view, "#fare-zone-assignment-more") == "and 50 more"
      refute has_element?(view, "#fare-zone-assignment-helper")
    end

    test "a changed selection is stated, cannot be saved and offers no Refresh", context do
      stop_ids = [context.stops["A1"].id, context.stops["A3"].id]

      {:ok, preview} =
        FareZones.preview_assignment(context.organization.id, context.version.id, stop_ids, "B")

      origin = %{
        session_pid: self(),
        conversation_id: "c",
        entry_id: 2,
        command: {:zone_assignment, %{}},
        summary: %{title: "Assign 2 stops to Zone B", detail: "", lines: ["Routes: 6"]},
        stop_routes: %{},
        return_focus_id: "agent-prepared-2",
        changed?: true
      }

      html =
        render_component(&FaresComponents.assignment_dialog/1,
          assignment: %{
            mode: :assign,
            target: "B",
            preview: preview,
            error: nil,
            stale: 0,
            origin: origin
          },
          zones: FareZones.inventory(context.organization.id, context.version.id).zones
        )

      assert html =~ "fare-zone-assignment-changed"
      assert html =~ "The routes&#39; stops or zones changed after this was prepared."
      assert html =~ "Close this review and ask the helper again."
      refute html =~ "fare-zone-assignment-refresh"
      assert html =~ ~r/id="fare-zone-assignment-dialog-confirm"[^>]*disabled/

      # A stale review of the same origin has no Refresh either.
      stale = %{
        mode: :assign,
        target: "B",
        preview: preview,
        error: nil,
        stale: 1,
        origin: %{origin | changed?: false}
      }

      html = render_component(&FaresComponents.assignment_dialog/1, assignment: stale, zones: [])
      assert html =~ "fare-zone-assignment-stale"
      refute html =~ "fare-zone-assignment-refresh"

      # A manual review keeps it.
      manual = %{stale | origin: nil}
      html = render_component(&FaresComponents.assignment_dialog/1, assignment: manual, zones: [])
      assert html =~ "fare-zone-assignment-refresh"
    end
  end

  describe "confirming a helper-origin review" do
    test "writes the prepared stops only, reports Undo and settles the card", context do
      {view, pid} = prepared_view(context)
      before = zone_by_stop_id()
      view |> element("#agent-review-prepared-2") |> render_click()

      view |> element("#fare-zone-assignment-dialog-confirm") |> render_click()

      assert zone_by_stop_id() == %{before | "A1" => "B", "A3" => "B"}
      refute has_element?(view, "#fare-zone-assignment-dialog")
      assert text_of(view, "#fare-zone-saved") =~ "2 stops assigned to Zone B."
      assert has_element?(view, "#fare-zone-undo")
      refute has_element?(view, "#agent-review-prepared-2")
      assert {:ok, ^pid, %{conversation_id: id}} = Agents.open(scope(context))
      assert Agents.prepared(pid, id, 2) == :error

      view |> element("#fare-zone-undo") |> render_click()

      assert zone_by_stop_id() == before
      assert text_of(view, "#fare-zone-saved") =~ "Change undone."
    end

    test "a stop that joined the route between review and confirm writes nothing", context do
      {view, _pid} = prepared_view(context)
      view |> element("#agent-review-prepared-2") |> render_click()
      before = zones()

      GtfsFixtures.stop_time_fixture(context.organization.id, context.version.id, "T6", "U1", %{
        stop_sequence: 9
      })

      view |> element("#fare-zone-assignment-dialog-confirm") |> render_click()

      assert zones() == before
      assert has_element?(view, "#fare-zone-assignment-dialog")
      assert has_element?(view, "#fare-zone-assignment-changed")
      assert has_element?(view, "#fare-zone-assignment-dialog-confirm[disabled]")
      refute has_element?(view, "#fare-zone-assignment-refresh")
      refute has_element?(view, "#fare-zone-saved")

      # A forged refresh from the browser changes nothing either.
      render_click(view, "refresh_assignment", %{})

      assert has_element?(view, "#fare-zone-assignment-changed")
      assert has_element?(view, "#fare-zone-assignment-row-2", "Cedar")
      assert zones() == before
    end

    test "a zone change on a served stop, selected or not, writes nothing", context do
      for {stop_id, zone} <- [{"A2", nil}, {"A1", "C"}] do
        {view, _pid} = prepared_view(context)
        view |> element("#agent-review-prepared-2") |> render_click()

        Repo.update_all(from(s in Stop, where: s.id == ^context.stops[stop_id].id),
          set: [zone_id: zone]
        )

        before = zones()

        view |> element("#fare-zone-assignment-dialog-confirm") |> render_click()

        assert zones() == before, "after changing #{stop_id}"
        assert has_element?(view, "#fare-zone-assignment-changed")
        assert has_element?(view, "#fare-zone-assignment-dialog-confirm[disabled]")
        refute has_element?(view, "#fare-zone-assignment-refresh")

        # Put the fixture back for the next stop's attempt, in a fresh view.
        original = if stop_id == "A2", do: "B", else: nil

        Repo.update_all(from(s in Stop, where: s.id == ^context.stops[stop_id].id),
          set: [zone_id: original]
        )

        GenServer.stop(assigns(view).agent_session)
      end
    end

    test "a revoked editor writes nothing and sees the save failure", context do
      {view, _pid} = prepared_view(context)
      view |> element("#agent-review-prepared-2") |> render_click()
      before = zones()

      deactivate_membership_fixture(context.membership)
      view |> element("#fare-zone-assignment-dialog-confirm") |> render_click()

      assert zones() == before
      assert has_element?(view, "#fare-zone-assignment-error", @save_failed)
    end

    test "saving another target keeps the card unapplied and says so", context do
      {view, pid} = prepared_view(context)
      view |> element("#agent-review-prepared-2") |> render_click()

      view |> element("#fare-zone-assignment-target-form") |> render_change(%{"target" => "C"})
      view |> element("#fare-zone-assignment-dialog-confirm") |> render_click()

      assert %{"A1" => "C", "A3" => "C", "A2" => "B"} = zone_by_stop_id()
      assert has_element?(view, "#fare-zone-undo")
      assert has_element?(view, "#agent-panel", @edited_notice)
      assert has_element?(view, "#agent-review-prepared-2")
      assert {:ok, ^pid, %{conversation_id: id}} = Agents.open(scope(context))
      assert {:ok, %{command: {:zone_assignment, %{target: "B"}}}} = Agents.prepared(pid, id, 2)
    end

    test "a manual review still saves through the unfenced path", context do
      {:ok, view, _html} = open_zones(context)

      for stop_id <- ["A1", "A3"],
          do: render_click(view, "toggle_stop", %{"id" => context.stops[stop_id].id})

      view |> element("#fare-zone-assign-selection") |> render_click()
      assert has_element?(view, "#fare-zone-assignment-dialog")
      refute has_element?(view, "#fare-zone-assignment-helper")

      GtfsFixtures.stop_time_fixture(context.organization.id, context.version.id, "T6", "U1", %{
        stop_sequence: 9
      })

      view |> element("#fare-zone-assignment-dialog-confirm") |> render_click()

      assert %{"A1" => "B", "A3" => "B"} = zone_by_stop_id()
      assert has_element?(view, "#fare-zone-saved")
    end
  end

  ## Helpers

  defp zone_by_stop_id,
    do: Repo.all(from(s in Stop, select: {s.stop_id, s.zone_id})) |> Map.new()

  defp text_of(view, selector) do
    view
    |> element(selector)
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.text()
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp zones,
    do: Repo.all(from(s in Stop, order_by: s.id, select: {s.id, s.zone_id, s.updated_at}))

  defp assigns(view), do: :sys.get_state(view.pid).socket.assigns

  # Opens the helper, attaches this process to the same conversation so the settled
  # entry can be awaited, and scripts the two provider replies of one prepare turn.
  defp prepared_view(context, arguments \\ @prepare_arguments) do
    {:ok, view, _html} = open_zones(context)
    view |> element("#agent-helper-open") |> render_click()

    pid = assigns(view).agent_session
    assert {:ok, ^pid, _snapshot} = Agents.open(scope(context))

    expect_reply(tool_calls_reply([{"call_1", "prepare_zone_assignment", arguments}]))
    expect_reply(text_reply("I prepared the zone assignment."))

    view
    |> element("#agent-composer")
    |> render_submit(%{"agent" => %{"message" => "Put those stops in Zone B"}})

    assert_receive {:agent_event, ^pid,
                    {:entry, %{status: :done, prepared: %{command: command}}}},
                   5_000

    assert {:zone_assignment, %{stop_ids: [_ | _]}} = command
    render(view)

    {view, pid}
  end

  defp scope(context) do
    %Scope{
      organization_id: context.organization.id,
      gtfs_version_id: context.version.id,
      user_id: context.user.id,
      user_email: context.user.email,
      pack_id: "fare_zones",
      version_name: context.version.name,
      resource_context: Scope.context({:version, context.version.id})
    }
  end

  defp log_in(conn, context),
    do: log_in_user(conn, context.user, organization: context.organization)

  defp open_zones(context) do
    build_conn()
    |> log_in(context)
    |> live("/gtfs/#{context.version.id}/settings/fares/zones")
  end
end
