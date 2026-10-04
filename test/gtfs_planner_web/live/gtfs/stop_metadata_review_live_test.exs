defmodule GtfsPlannerWeb.Gtfs.StopMetadataReviewLiveTest do
  @moduledoc """
  Merge evidence (EV-25) for the review of a prepared stop batch on the real stops
  catalog.

  The batch is prepared by the real session with only the provider's HTTP boundary
  scripted, and `Review stop changes` is pressed on the card. The review table is read
  back from the page, and the stops, their update stamps and the audit log are compared
  before and after to show the review writes nothing. Expected values are written by
  hand from the fixture:

    * `S410` Elm Street Station, code `E-1`
    * `S411` Pine Plaza, code `P-1`
    * `S412` Oak Court, which is approved but only ever the name another stop duplicates
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
  alias GtfsPlanner.Gtfs.ChangeLog
  alias GtfsPlanner.Gtfs.Stop
  alias GtfsPlanner.Repo

  setup %{conn: conn} do
    Req.Test.set_req_test_to_shared()
    ScriptedProvider.track_sessions()

    organization = organization_fixture()
    user = user_fixture()

    {:ok, _membership} =
      Accounts.create_user_org_membership(%{
        user_id: user.id,
        organization_id: organization.id,
        roles: ["pathways_studio_editor"]
      })

    version = gtfs_version_fixture(organization.id)

    stops =
      for {stop_id, name, code} <- [
            {"S410", "Elm Street Station", "E-1"},
            {"S411", "Pine Plaza", "P-1"},
            {"S412", "Oak Court", nil}
          ],
          into: %{} do
        stop = stop_fixture(organization.id, version.id, %{stop_id: stop_id, stop_name: name})
        # The insert fixture does not cast the code, so it is written as an import writes it.
        set_stop(stop, stop_code: code)
        {stop_id, stop}
      end

    %{conn: log_in_user(conn, user, organization: organization), version: version, stops: stops}
  end

  setup {Req.Test, :verify_on_exit!}

  describe "reviewing a prepared batch" do
    test "shows one row per changed field with the current and new values and writes nothing",
         context do
      {view, entry} =
        prepared_view(context, [
          %{"stop_id" => "S411", "stop_name" => "Pine Square"},
          %{"stop_id" => "S410", "stop_name" => "Elm Street", "stop_code" => "E-2"}
        ])

      before = stamps()
      view |> element("#agent-review-prepared-#{entry}") |> render_click()

      assert has_element?(view, "#stop-review")
      assert has_element?(view, "#stop-review-table")

      assert has_element?(
               view,
               "#stop-review-overlay[data-return-focus-id=\"agent-prepared-#{entry}\"]"
             )

      # Rows are sorted by stop ID, one per changed field, with the stored current value.
      assert review_rows(view, context.stops["S410"]) == [
               {["S410", "Elm Street Station"], "Name", "Elm Street Station", "Elm Street"},
               {["S410"], "Code", "E-1", "E-2"}
             ]

      assert review_rows(view, context.stops["S411"]) == [
               {["S411", "Pine Plaza"], "Name", "Pine Plaza", "Pine Square"}
             ]

      refute has_element?(view, "#stop-review-unchanged")
      refute has_element?(view, "#stop-review-warnings")
      refute has_element?(view, "#stop-review-invalid")
      assert stamps() == before
    end

    test "a stop already at its prepared value is counted, not listed; another editor's change shows as current",
         context do
      {view, entry} =
        prepared_view(context, [
          %{"stop_id" => "S410", "stop_name" => "Elm Street"},
          %{"stop_id" => "S411", "stop_name" => "Pine Square"}
        ])

      # S410 already has its new name, and S411 was renamed by someone else meanwhile.
      set_stop(context.stops["S410"], stop_name: "Elm Street")
      set_stop(context.stops["S411"], stop_name: "Pine Plaza Terminal")

      view |> element("#agent-review-prepared-#{entry}") |> render_click()

      assert has_element?(view, "#stop-review-unchanged", "1 stop already has these values")
      refute has_element?(view, "#stop-review-stop-#{context.stops["S410"].id}")

      assert review_rows(view, context.stops["S411"]) == [
               {["S411", "Pine Plaza Terminal"], "Name", "Pine Plaza Terminal", "Pine Square"}
             ]
    end

    test "a new name that another stop uses is a warning naming that stop", context do
      {view, entry} =
        prepared_view(context, [%{"stop_id" => "S410", "stop_name" => "Oak Court"}])

      view |> element("#agent-review-prepared-#{entry}") |> render_click()

      assert has_element?(view, "#stop-review-warnings", "S410 would be named “Oak Court”")
      assert has_element?(view, "#stop-review-warnings", "S412 already uses")
      # A warning does not block the review.
      assert has_element?(view, "#stop-review-table")
      refute has_element?(view, "#stop-review-invalid")
    end

    test "a stop that became invalid shows its error and the drawer says so", context do
      {view, entry} =
        prepared_view(context, [%{"stop_id" => "S410", "stop_name" => "Elm Street"}])

      # A located stop must keep its coordinates.
      set_stop(context.stops["S410"], stop_lat: nil, stop_lon: nil)
      before = stamps()

      view |> element("#agent-review-prepared-#{entry}") |> render_click()

      assert has_element?(view, "#stop-review-invalid", "1 stop cannot be saved")

      assert has_element?(
               view,
               "#stop-review-stop-#{context.stops["S410"].id}",
               "S410 cannot be saved"
             )

      assert has_element?(view, "#stop-review-stop-#{context.stops["S410"].id}", "stop_lat: ")
      assert assigns(view).stop_review.review.valid? == false
      assert stamps() == before
    end

    test "a stop deleted after approval makes the card stale and opens no drawer", context do
      {view, entry} =
        prepared_view(context, [%{"stop_id" => "S410", "stop_name" => "Elm Street"}])

      # The helper's admission refuses a set with a missing stop before the review reads
      # anything, so the card reads as stale rather than reaching a partial table.
      stop_uuid = context.stops["S410"].id
      Repo.delete_all(from(s in Stop, where: s.id == ^stop_uuid))

      view |> element("#agent-review-prepared-#{entry}") |> render_click()

      refute has_element?(view, "#stop-review")
      assert has_element?(view, "#agent-notice", "That request is no longer current. Ask again.")
    end
  end

  describe "forged and stale events" do
    test "an unparsable entry changes nothing and an unknown one is a stale request",
         context do
      {view, entry} =
        prepared_view(context, [%{"stop_id" => "S410", "stop_name" => "Elm Street"}])

      for params <- [%{"entry" => "x"}, %{"entry" => "1x"}, %{"entry" => 1}, %{}] do
        render_hook(view, "agent_review_prepared", params)
        refute has_element?(view, "#stop-review")
        refute has_element?(view, "#agent-notice")
      end

      render_hook(view, "agent_review_prepared", %{"entry" => "99999"})
      refute has_element?(view, "#stop-review")
      assert has_element?(view, "#agent-notice", "That request is no longer current. Ask again.")

      # The real card still reviews.
      view |> element("#agent-review-prepared-#{entry}") |> render_click()
      assert has_element?(view, "#stop-review")
    end

    test "a card from an earlier conversation or a page with no session reviews nothing",
         context do
      {view, entry} =
        prepared_view(context, [%{"stop_id" => "S410", "stop_name" => "Elm Street"}])

      # Approving another set starts a new conversation; the old card's entry is stale.
      approve(view, "S410\nS411")
      eventually(fn -> assigns(view).agent_entries_empty? end)
      render_hook(view, "agent_review_prepared", %{"entry" => Integer.to_string(entry)})

      refute has_element?(view, "#stop-review")
      assert has_element?(view, "#agent-notice", "That request is no longer current. Ask again.")

      # Clearing the set closes the helper and leaves no session at all.
      view |> element("#stop-set-clear") |> render_click()
      assert assigns(view).agent_session == nil
      render_hook(view, "agent_review_prepared", %{"entry" => Integer.to_string(entry)})
      refute has_element?(view, "#stop-review")
    end

    test "closing the drawer removes it and a changed set discards an open review", context do
      {view, entry} =
        prepared_view(context, [%{"stop_id" => "S410", "stop_name" => "Elm Street"}])

      view |> element("#agent-review-prepared-#{entry}") |> render_click()
      view |> element("#stop-review-close") |> render_click()

      refute has_element?(view, "#stop-review")
      assert assigns(view).stop_review == nil

      view |> element("#agent-review-prepared-#{entry}") |> render_click()
      assert has_element?(view, "#stop-review")

      # A forged approval while the drawer is open replaces the conversation, so the
      # review that belonged to it goes too.
      approve(view, "S410")
      refute has_element?(view, "#stop-review")
    end
  end

  # -- helpers ----------------------------------------------------------------

  defp set_stop(stop, changes),
    do: Repo.update_all(from(s in Stop, where: s.id == ^stop.id), set: changes)

  # Every stop's text, stamps and lock, plus the audit log: what a review must not touch.
  defp stamps do
    {Repo.all(
       from(s in Stop,
         order_by: s.id,
         select: {s.id, s.stop_name, s.stop_code, s.updated_at, s.lock_version}
       )
     ), Repo.aggregate(ChangeLog, :count)}
  end

  # The approved set S410, S411 and S412, the helper open, and the batch prepared by the
  # session; returns the view and the card's entry ID.
  defp prepared_view(context, rows) do
    {:ok, view, _html} = live(context.conn, ~p"/gtfs/#{context.version.id}/stops")
    view |> element("#stop-set-toggle") |> render_click()
    approve(view, "S410\nS411\nS412")
    view |> element("#agent-helper-open") |> render_click()

    ScriptedProvider.expect_tool_turn(
      "prepare_stop_metadata_changes",
      Jason.encode!(%{"rows" => rows}),
      "I prepared the changes."
    )

    view
    |> element("#agent-composer")
    |> render_submit(%{"agent" => %{"message" => "Rename these stops."}})

    {view, await_entry(view)}
  end

  defp approve(view, text) do
    view |> form("#stop-set-form", stop_set: %{refs: text}) |> render_submit()
    view |> element("#stop-set-approve") |> render_click()
  end

  defp await_entry(view, attempts \\ 100) do
    case Regex.run(~r/id="agent-review-prepared-(\d+)"/, render(view)) do
      [_match, id] ->
        String.to_integer(id)

      nil when attempts > 0 ->
        Process.sleep(50)
        await_entry(view, attempts - 1)

      nil ->
        flunk("the prepared card never appeared")
    end
  end

  # The drawer's rows for one stop as {stop cell, field, current, new}, in table order.
  defp review_rows(view, stop) do
    view
    |> element("#stop-review-table")
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("tbody[id=\"stop-review-stop-#{stop.id}\"] tr")
    |> Enum.filter(&(cell(&1, "Field") != ""))
    |> Enum.map(&{stop_cell(&1), cell(&1, "Field"), cell(&1, "Current"), cell(&1, "New")})
  end

  # The stop cell's ID, and its current name on the stop's first row.
  defp stop_cell(row) do
    row
    |> LazyHTML.query(~s(td[data-label="Stop"] span))
    |> Enum.map(&(&1 |> LazyHTML.text() |> String.trim()))
  end

  defp cell(row, label) do
    row
    |> LazyHTML.query(~s(td[data-label="#{label}"]))
    |> LazyHTML.text()
    |> String.split()
    |> Enum.join(" ")
  end
end
