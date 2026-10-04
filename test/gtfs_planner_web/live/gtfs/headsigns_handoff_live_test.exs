defmodule GtfsPlannerWeb.Gtfs.HeadsignsHandoffLiveTest do
  @moduledoc """
  Merge evidence (EV-6) for the `Review headsigns` handoff on the real pattern page.

  A prepared card is produced by the real session with only the provider's HTTP
  boundary scripted. Pressing its button must only seed the page's own headsign
  staging and open the existing change drawer; every refusal leaves rows, assigns
  and drafts as they were. Expected sets come from the A01 fixture in
  `GtfsPlanner.HeadsignHelperFixtures`: twelve followers of `Downtown Terminal`,
  two `Peak` trips, and three trips that must never move.
  """

  use GtfsPlannerWeb.ConnCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.HeadsignHelperFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures
  import GtfsPlannerWeb.HeadsignHelperLiveHelpers, only: [assigns: 1, pattern_args: 0, stamps: 0]

  alias GtfsPlanner.Agents.ScriptedProvider
  alias GtfsPlanner.Gtfs.RoutePattern
  alias GtfsPlanner.Gtfs.Trip
  alias GtfsPlanner.Repo
  alias GtfsPlannerWeb.HeadsignHelperLiveHelpers

  @timing_args ~s({"current_text":"Peak Terminal","new_text":"Rush Terminal"})

  setup %{conn: conn} do
    Req.Test.set_req_test_to_shared()
    ScriptedProvider.track_sessions()

    organization = organization_fixture()
    user = user_fixture()

    {:ok, _membership} =
      GtfsPlanner.Accounts.create_user_org_membership(%{
        user_id: user.id,
        organization_id: organization.id,
        roles: ["pathways_studio_editor"]
      })

    version = gtfs_version_fixture(organization.id)
    a01 = a01_fixture(organization.id, version.id)
    conn = log_in_user(conn, user, organization: organization)

    %{conn: conn, organization: organization, version: version, a01: a01}
  end

  setup {Req.Test, :verify_on_exit!}

  describe "pattern scope" do
    test "seeds the Details field, the Also-update box and the drawer without saving", context do
      {view, entry} = prepared_view(context, "?task=details")
      before = stamps()

      view |> element("#agent-review-prepared-#{entry}") |> render_click()

      assert has_element?(view, "#pattern-details-headsign[value='Central Station']")

      assert has_element?(
               view,
               "#headsign-update-box",
               "Also update 12 trips that show Downtown Terminal"
             )

      assert has_element?(view, "#headsign-review-drawer")
      assert has_element?(view, "#headsign-review-drawer-status", "12 trips selected")

      assigns = assigns(view)
      assert assigns.headsign_review.mode == :change
      assert assigns.headsign_review.opener_id == "agent-prepared-#{entry}"
      assert assigns.headsign_review.selected == MapSet.new(follower_ids(context))
      assert assigns.headsign_selection.ids == MapSet.new(follower_ids(context))
      assert assigns.headsign_origin.entry_id == entry
      assert assigns.agent_notice == nil

      # Nothing is saved: no trip, pattern, timing or audit row moved.
      assert stamps() == before
    end

    test "Use selection, Save and the dialog-free save write exactly the prepared set", context do
      {view, entry} = prepared_view(context, "?task=details")

      view |> element("#agent-review-prepared-#{entry}") |> render_click()
      view |> element("#headsign-review-drawer-use") |> render_click()

      view
      |> element("#pattern-details-form")
      |> render_submit(%{
        "pattern" => %{
          "name" => "Downtown",
          "direction_id" => "0",
          "headsign" => "Central Station",
          "time_desc" => "",
          "typicality" => "0",
          "sort_order" => "0"
        }
      })

      assert Repo.get!(RoutePattern, context.a01.pattern.id).headsign == "Central Station"

      renamed =
        Repo.all(from(t in Trip, where: t.trip_headsign == "Central Station", select: t.id))

      assert Enum.sort(renamed) == follower_ids(context)

      # The protected trips keep their exact stored text.
      assert stored_headsign(context, "A01-I1") == "Downtown Terminal, continues to Airport"
      assert stored_headsign(context, "A01-C1") == "downtown terminal"
      assert stored_headsign(context, "A01-P1") == "Peak Terminal"
    end

    test "closing returns focus to the card, and pressing again reopens without reseeding",
         context do
      {view, entry} = prepared_view(context, "?task=details")

      view |> element("#agent-review-prepared-#{entry}") |> render_click()
      origin = assigns(view).headsign_origin
      selection = assigns(view).headsign_selection

      view |> element("#headsign-review-drawer-cancel") |> render_click()
      refute has_element?(view, "#headsign-review-drawer")

      view |> element("#agent-review-prepared-#{entry}") |> render_click()

      assert has_element?(view, "#headsign-review-drawer-status", "12 trips selected")
      assert assigns(view).headsign_origin == origin
      assert assigns(view).headsign_selection == selection
      assert assigns(view).headsign_review.opener_id == "agent-prepared-#{entry}"
    end
  end

  describe "timing scope" do
    test "seeds the Running-times draft, opens its disclosure and selects the timing's trips",
         context do
      peak = context.a01.peak
      {view, entry} = prepared_view(context, "?task=timings&timing=#{peak.id}", @timing_args)
      before = stamps()

      view |> element("#agent-review-prepared-#{entry}") |> render_click()

      assigns = assigns(view)
      assert assigns.timing_headsign_edits[peak.id] == "Rush Terminal"
      assert assigns.timing_headsign == "Rush Terminal"
      assert assigns.timing_headsign_open? == true
      assert has_element?(view, "#headsign-review-drawer-status", "2 trips selected")

      assert assigns.headsign_review.selected ==
               MapSet.new([trip_id(context, "A01-P1"), trip_id(context, "A01-P2")])

      assert stamps() == before
    end
  end

  describe "refusals leave the page exactly as it was" do
    test "another editor renamed the default after the card was prepared", context do
      {view, entry} = prepared_view(context, "?task=details")

      Repo.update_all(from(p in RoutePattern, where: p.id == ^context.a01.pattern.id),
        set: [headsign: "Uptown Terminal"]
      )

      refused(view, entry, "headsigns changed since this request was prepared")
    end

    test "a listed trip was edited after the card was prepared", context do
      {view, entry} = prepared_view(context, "?task=details")

      Repo.update_all(from(t in Trip, where: t.id == ^trip_id(context, "A01-F05")),
        set: [trip_headsign: "Somewhere Else"]
      )

      refused(view, entry, "headsigns changed since this request was prepared")
    end

    test "the Details form has an unsaved edit", context do
      {view, entry} = prepared_view(context, "?task=details")
      render_change(view, "validate_details", %{"pattern" => %{"name" => "Edited name"}})

      refused(view, entry, "Save or discard your edits")
    end

    test "the impact dialog is open", context do
      {view, entry} = prepared_view(context, "?task=details")

      render_change(view, "validate_details", %{"pattern" => %{"direction_id" => "1"}})

      view
      |> element("#pattern-details-form")
      |> render_submit(%{
        "pattern" => %{
          "name" => "Downtown",
          "direction_id" => "1",
          "headsign" => "Downtown Terminal",
          "time_desc" => "",
          "typicality" => "0",
          "sort_order" => "0"
        }
      })

      assert assigns(view).impact_dialog != nil
      refused(view, entry, "Finish the review that is open")
    end

    test "the page moved to another task, which started a new conversation", context do
      {view, entry} = prepared_view(context, "?task=details")

      view |> element("#pattern-task-timings") |> render_click()
      assert assigns(view).agent_entries_empty? == true

      refused(view, entry, "no longer current")
    end

    test "a forged, foreign or missing entry does nothing and does not raise", context do
      {:ok, view, _html} =
        live(context.conn, "/gtfs/#{context.version.id}/routes/R1/patterns/A01-P1?task=details")

      # No session yet: nothing to look up.
      before = native_state(view)
      render_hook(view, "agent_review_prepared", %{"entry" => "2"})
      assert native_state(view) == before

      view |> element("#agent-helper-open") |> render_click()

      for forged <- [%{"entry" => "999"}, %{"entry" => "abc"}, %{"entry" => 2}, %{}] do
        render_hook(view, "agent_review_prepared", forged)
        refute has_element?(view, "#headsign-review-drawer")
        assert native_state(view) == before
      end

      # An entry of an earlier conversation is not the current one's.
      {view, entry} = prepared_view(context, "?task=details")
      view |> element("#agent-new-conversation") |> render_click()

      refused(view, entry, "no longer current")
    end
  end

  # -- helpers ----------------------------------------------------------------

  # Presses the card's button and asserts the refusal: a notice, no drawer, and
  # the same rows and native state.
  defp refused(view, entry, notice) do
    rows = stamps()
    native = native_state(view)

    render_hook(view, "agent_review_prepared", %{"entry" => Integer.to_string(entry)})

    assert has_element?(view, "#agent-notice", notice)
    refute has_element?(view, "#headsign-review-drawer")
    assert assigns(view).headsign_origin == nil
    assert native_state(view) == native
    assert stamps() == rows
  end

  defp prepared_view(context, query, arguments \\ pattern_args()),
    do: HeadsignHelperLiveHelpers.prepared_view(context.conn, context.version, query, arguments)

  defp trip_id(context, name), do: HeadsignHelperLiveHelpers.trip_id(context.a01, name)

  defp stored_headsign(context, name),
    do: HeadsignHelperLiveHelpers.stored_headsign(context.a01, name)

  defp follower_ids(context), do: HeadsignHelperLiveHelpers.follower_ids(context.a01)

  defp native_state(view) do
    Map.take(assigns(view), [
      :details_params,
      :details_form,
      :timing_headsign_edits,
      :timing_headsign,
      :timing_headsign_open?,
      :headsign_selection,
      :impact_dialog,
      :dirty?
    ])
  end
end
