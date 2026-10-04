defmodule GtfsPlannerWeb.Gtfs.HeadsignsReceiptLiveTest do
  @moduledoc """
  Merge evidence (EV-7): a prepared headsign card is marked applied only when the
  native save equals the prepared command.

  Every case hands a real prepared card to the real pattern page and saves through
  its own form, so the receipt comes from the page's `apply_details/3` and
  `apply_timing/4` and the session's `record_applied/4` equality, never from a
  test-built command. The A01 fixture is `GtfsPlanner.HeadsignHelperFixtures`.
  """

  use GtfsPlannerWeb.ConnCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.HeadsignHelperFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures
  import GtfsPlannerWeb.HeadsignHelperLiveHelpers, only: [assigns: 1, eventually: 1, stamps: 0]

  alias GtfsPlanner.Agents.ScriptedProvider
  alias GtfsPlanner.Gtfs.RoutePattern
  alias GtfsPlanner.Gtfs.TimedPattern
  alias GtfsPlanner.Gtfs.Trip
  alias GtfsPlanner.Repo
  alias GtfsPlannerWeb.HeadsignHelperLiveHelpers

  @timing_args ~s({"current_text":"Peak Terminal","new_text":"Rush Terminal"})
  @unconfirmed "You changed the request before saving, so the original card stays unconfirmed."

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
    test "the identical native save marks the card applied", context do
      {view, entry} = handed_off(context)

      view |> element("#headsign-review-drawer-use") |> render_click()
      save_details(view)

      assert Repo.get!(RoutePattern, context.a01.pattern.id).headsign == "Central Station"
      assert renamed("Central Station") == follower_ids(context)

      # The native saved message and Undo are unchanged.
      assert has_element?(view, "#headsign-result", "Headsign saved · 12 trips updated")
      assert has_element?(view, "#headsign-undo", "Undo headsign change")

      eventually(fn -> applied?(view, entry) end)
      assert has_element?(view, "#agent-prepared-#{entry}", "Applied")
      assert assigns(view).headsign_origin == nil
      assert assigns(view).agent_notice == nil
    end

    test "adding the lowercase trip in the drawer leaves the card unconfirmed", context do
      {view, entry} = handed_off(context)

      # The editor adds the likely-typo trip to the staged selection before saving.
      typo = trip_id(context, "A01-C1")

      render_click(view, "select_headsign_trip", %{"trip" => typo})

      view |> element("#headsign-review-drawer-use") |> render_click()
      save_details(view)

      assert length(renamed("Central Station")) == 13
      assert typo in renamed("Central Station")

      refute applied?(view, entry)
      assert has_element?(view, "#agent-review-prepared-#{entry}")
      assert has_element?(view, "#agent-notice", @unconfirmed)
      assert assigns(view).headsign_origin == nil
    end

    test "also editing the pattern name leaves the card unconfirmed, with both changes saved",
         context do
      {view, entry} = handed_off(context)

      view |> element("#headsign-review-drawer-use") |> render_click()
      save_details(view, name: "Downtown Loop")

      pattern = Repo.get!(RoutePattern, context.a01.pattern.id)

      assert {pattern.route_pattern_name, pattern.headsign} ==
               {"Downtown Loop", "Central Station"}

      assert renamed("Central Station") == follower_ids(context)

      refute applied?(view, entry)
      assert has_element?(view, "#agent-notice", @unconfirmed)
    end

    test "a save refused as stale leaves the origin, the drafts and the card alone", context do
      {view, entry} = handed_off(context)
      view |> element("#headsign-review-drawer-use") |> render_click()

      origin = assigns(view).headsign_origin
      selection = assigns(view).headsign_selection

      # Another editor changes the pattern after the page loaded it.
      Repo.update_all(from(p in RoutePattern, where: p.id == ^context.a01.pattern.id),
        set: [route_pattern_name: "Renamed elsewhere", updated_at: DateTime.utc_now()]
      )

      before = stamps()
      save_details(view)

      assert assigns(view).details_stale? == true
      assert assigns(view).headsign_origin == origin
      assert assigns(view).headsign_selection == selection
      assert assigns(view).details_params["headsign"] == "Central Station"
      refute applied?(view, entry)
      assert has_element?(view, "#agent-review-prepared-#{entry}")
      assert stamps() == before
    end

    test "an origin whose conversation was reset ends quietly with no badge", context do
      {view, entry} = handed_off(context)
      view |> element("#headsign-review-drawer-use") |> render_click()

      # A new conversation retires the card; the page still holds the staged origin.
      view |> element("#agent-new-conversation") |> render_click()
      assert assigns(view).headsign_origin != nil

      save_details(view)

      assert renamed("Central Station") == follower_ids(context)
      assert has_element?(view, "#headsign-result")
      refute has_element?(view, "#agent-review-prepared-#{entry}")
      refute has_element?(view, "#agent-notice", @unconfirmed)
      assert assigns(view).agent_notice == nil
    end
  end

  describe "timing scope" do
    test "the identical native save marks the card applied", context do
      {view, entry} = handed_off_timing(context)

      view |> element("#headsign-review-drawer-use") |> render_click()
      save_timing(view)

      assert Repo.get!(TimedPattern, context.a01.peak.id).headsign == "Rush Terminal"

      assert Enum.sort(renamed("Rush Terminal")) ==
               Enum.sort([trip_id(context, "A01-P1"), trip_id(context, "A01-P2")])

      eventually(fn -> applied?(view, entry) end)
      assert assigns(view).agent_notice == nil
    end

    test "a different trip selection leaves the card unconfirmed", context do
      {view, entry} = handed_off_timing(context)

      first = trip_id(context, "A01-P1")

      render_click(view, "select_headsign_trip", %{"trip" => first})

      view |> element("#headsign-review-drawer-use") |> render_click()
      save_timing(view)

      assert renamed("Rush Terminal") == [trip_id(context, "A01-P2")]
      refute applied?(view, entry)
      assert has_element?(view, "#agent-notice", @unconfirmed)
    end
  end

  # -- helpers ----------------------------------------------------------------

  defp handed_off(context) do
    {view, entry} =
      HeadsignHelperLiveHelpers.prepared_view(context.conn, context.version, "?task=details")

    view |> element("#agent-review-prepared-#{entry}") |> render_click()
    assert has_element?(view, "#headsign-review-drawer")
    {view, entry}
  end

  defp handed_off_timing(context) do
    {view, entry} =
      HeadsignHelperLiveHelpers.prepared_view(
        context.conn,
        context.version,
        "?task=timings&timing=#{context.a01.peak.id}",
        @timing_args
      )

    view |> element("#agent-review-prepared-#{entry}") |> render_click()
    assert has_element?(view, "#headsign-review-drawer")
    {view, entry}
  end

  # The page's own Details Save, with the values the page already holds.
  defp save_details(view, overrides \\ []) do
    view
    |> element("#pattern-details-form")
    |> render_submit(%{
      "pattern" => %{
        "name" => Keyword.get(overrides, :name, "Downtown"),
        "direction_id" => "0",
        "headsign" => "Central Station",
        "time_desc" => "",
        "typicality" => "0",
        "sort_order" => "0"
      }
    })
  end

  defp save_timing(view), do: view |> element("#timing-save") |> render_click()

  # The card is applied once its entry no longer offers the review button.
  defp applied?(view, entry) do
    html = render(view)

    not (html =~ ~s(id="agent-review-prepared-#{entry}")) and
      html =~ ~s(id="agent-prepared-#{entry}")
  end

  defp renamed(headsign),
    do:
      Repo.all(from(t in Trip, where: t.trip_headsign == ^headsign, select: t.id)) |> Enum.sort()

  defp trip_id(context, name), do: HeadsignHelperLiveHelpers.trip_id(context.a01, name)
  defp follower_ids(context), do: HeadsignHelperLiveHelpers.follower_ids(context.a01)
end
