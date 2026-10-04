defmodule GtfsPlannerWeb.Gtfs.StopSetApprovalLiveTest do
  @moduledoc """
  Merge evidence (EV-21) for the stops catalog's approval form: the editor, not the
  model, chooses the stops the text helper may work on.

  The page is the real `/gtfs/:version/stops` route. Expected sets are written by hand
  from the fixture below, never read back from the resolver:

    * `S410` Elm Street Station
    * `S500` Pine Plaza, code `C-77`
    * `S600` and `S601`, both named `Main St @ Elm` (S601 inside station `S410`)
    * `S700` Oak Court, which only the form's forged events ever name
  """

  use GtfsPlannerWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures
  import GtfsPlannerWeb.HeadsignHelperLiveHelpers, only: [assigns: 1]
  import Phoenix.LiveViewTest

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Gtfs.Stop
  alias GtfsPlanner.Repo

  setup %{conn: conn} do
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
      for {stop_id, name} <- [
            {"S410", "Elm Street Station"},
            {"S500", "Pine Plaza"},
            {"S600", "Main St @ Elm"},
            {"S601", "Main St @ Elm"},
            {"S700", "Oak Court"}
          ],
          into: %{} do
        {stop_id, stop_fixture(organization.id, version.id, %{stop_id: stop_id, stop_name: name})}
      end

    # The insert fixture does not cast these two, so they are written as an import writes them.
    set_stop(stops["S500"], stop_code: "C-77")
    set_stop(stops["S601"], parent_station: "S410")

    %{
      conn: log_in_user(conn, user, organization: organization),
      organization: organization,
      version: version,
      stops: stops
    }
  end

  defp set_stop(stop, changes),
    do: Repo.update_all(from(s in Stop, where: s.id == ^stop.id), set: changes)

  defp open_form(%{conn: conn, version: version}) do
    {:ok, view, _html} = live(conn, ~p"/gtfs/#{version.id}/stops")
    view |> element("#stop-set-toggle") |> render_click()
    view
  end

  defp find(view, text) do
    view |> form("#stop-set-form", stop_set: %{refs: text}) |> render_submit()
  end

  defp approved_ids(view) do
    view
    |> element("#stop-set-list")
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("li")
    |> LazyHTML.attribute("data-stop-id")
  end

  @mixed "S410\nC-77\nMain St @ Elm\nNowhere\nS410\n"

  describe "resolving pasted lines" do
    test "shows each match with its basis, the ambiguity with a skip choice, and the unmatched line",
         context do
      {:ok, view, _html} = live(context.conn, ~p"/gtfs/#{context.version.id}/stops")

      assert has_element?(view, ~s(#stop-set-toggle[aria-expanded="false"]))
      refute has_element?(view, "#stop-set-form")

      view |> element("#stop-set-toggle") |> render_click()
      assert has_element?(view, ~s(#stop-set-toggle[aria-expanded="true"]))
      assert has_element?(view, "#stop-set-summary", "No stops approved")

      find(view, @mixed)

      assert has_element?(view, "#stop-set-resolution-heading", "2 stops found")
      assert has_element?(view, "#stop-set-resolved li", "Matched by stop ID: S410")
      assert has_element?(view, "#stop-set-resolved li", "Matched by code: C-77")
      # The repeated S410 line collapses into the first.
      assert view |> element("#stop-set-resolved") |> render() |> String.split("<li") |> length() ==
               3

      assert has_element?(view, "#stop-set-ambiguity-0 legend", "matches 2 stops by name")
      assert has_element?(view, ~s(#stop-set-choice-0-S600[type="radio"]))
      assert has_element?(view, ~s(#stop-set-choice-0-S601[type="radio"]))
      assert has_element?(view, ~s(#stop-set-skip-0[type="radio"]))
      assert has_element?(view, "#stop-set-ambiguity-0", "Parent S410")
      assert has_element?(view, "#stop-set-unmatched li", "Nowhere")

      assert has_element?(view, "#stop-set-approve[disabled]")
      assert has_element?(view, "#stop-set-approve-reason", "Choose a stop or skip 1 line first.")
    end

    test "stops of another version or organization are unmatched, never listed", context do
      other_version = gtfs_version_fixture(context.organization.id)
      stop_fixture(context.organization.id, other_version.id, %{stop_id: "S800"})

      foreign = organization_fixture()
      foreign_version = gtfs_version_fixture(foreign.id)

      stop_fixture(foreign.id, foreign_version.id, %{
        stop_id: "S810",
        stop_name: "Elm Street Station"
      })

      view = open_form(context)
      find(view, "S800\nS810")

      assert has_element?(view, "#stop-set-unmatched li", "S800")
      assert has_element?(view, "#stop-set-unmatched li", "S810")
      refute has_element?(view, "#stop-set-resolved")
      assert has_element?(view, "#stop-set-approve[disabled]")
      assert has_element?(view, "#stop-set-approve-reason", "No stop is selected.")
    end

    test "101 lines and a 201-character line show an inline error and keep the typed text",
         context do
      view = open_form(context)

      too_many = Enum.map_join(1..101, "\n", &"X#{&1}")
      find(view, too_many)

      assert has_element?(view, ~s(#stop-set-refs[aria-invalid="true"]))
      assert has_element?(view, "#stop-set-form", "Enter up to 100 lines")
      assert has_element?(view, "#stop-set-refs", "X101")
      refute has_element?(view, "#stop-set-resolution")

      long = String.duplicate("a", 201)
      find(view, long)

      assert has_element?(view, "#stop-set-form", "200 characters or fewer")
      assert has_element?(view, "#stop-set-refs", long)

      find(view, "  \n\n")
      assert has_element?(view, "#stop-set-form", "Enter at least one stop ID")
    end
  end

  describe "approving" do
    test "a chosen candidate enables approval and the sorted set is stored", context do
      view = open_form(context)
      find(view, @mixed)

      view |> element("#stop-set-choice-0-S601") |> render_click()
      refute has_element?(view, "#stop-set-approve[disabled]")
      assert has_element?(view, "#stop-set-choice-0-S601[checked]")

      view |> element("#stop-set-approve") |> render_click()

      assert has_element?(view, "#stop-set-summary", "3 stops approved")
      assert approved_ids(view) == ["S410", "S500", "S601"]
      refute has_element?(view, "#stop-set-resolution")

      stops = context.stops

      assert assigns(view).stop_set == [
               %{uuid: stops["S410"].id, stop_id: "S410", stop_name: "Elm Street Station"},
               %{uuid: stops["S500"].id, stop_id: "S500", stop_name: "Pine Plaza"},
               %{uuid: stops["S601"].id, stop_id: "S601", stop_name: "Main St @ Elm"}
             ]
    end

    test "a skipped ambiguity is left out and Clear stops empties the set", context do
      view = open_form(context)
      find(view, @mixed)

      view |> element("#stop-set-skip-0") |> render_click()
      view |> element("#stop-set-approve") |> render_click()

      assert has_element?(view, "#stop-set-summary", "2 stops approved")
      assert approved_ids(view) == ["S410", "S500"]

      view |> element("#stop-set-clear") |> render_click()

      assert has_element?(view, "#stop-set-summary", "No stops approved")
      refute has_element?(view, "#stop-set-clear")
      refute has_element?(view, "#stop-set-list")
      assert assigns(view).stop_set == nil
    end

    test "an approved stop deleted before approval is refused and nothing is approved",
         context do
      view = open_form(context)
      find(view, "S410\nS500")

      Repo.delete!(context.stops["S500"])
      view |> element("#stop-set-approve") |> render_click()

      assert has_element?(view, "#stop-set-notice", "no longer exists")
      assert has_element?(view, "#stop-set-summary", "No stops approved")
      assert assigns(view).stop_set == nil
      refute has_element?(view, "#stop-set-resolution")
    end
  end

  describe "holding the set" do
    test "editing the text drops the resolution but keeps an approved set", context do
      view = open_form(context)
      find(view, "S410")
      view |> element("#stop-set-approve") |> render_click()
      find(view, "S500")
      assert has_element?(view, "#stop-set-resolution")

      # A change that leaves the text as it was changes nothing.
      view |> form("#stop-set-form", stop_set: %{refs: "S500"}) |> render_change()
      assert has_element?(view, "#stop-set-resolution")

      view |> form("#stop-set-form", stop_set: %{refs: "S50"}) |> render_change()

      refute has_element?(view, "#stop-set-resolution")
      assert has_element?(view, "#stop-set-summary", "1 stop approved")
      assert approved_ids(view) == ["S410"]
    end

    test "the set survives a catalog filter and a version switch starts empty", context do
      view = open_form(context)
      find(view, "S410")
      view |> element("#stop-set-approve") |> render_click()

      view |> element("#stop-search-form") |> render_change(%{search: "Pine"})
      assert has_element?(view, "#stop-set-summary", "1 stop approved")

      other_version = gtfs_version_fixture(context.organization.id)
      stop_fixture(context.organization.id, other_version.id, %{stop_id: "S410"})

      render_hook(view, "gtfs_version_loaded", %{"version_id" => other_version.id})
      path = ~p"/gtfs/#{other_version.id}/stops"
      assert_redirect(view, path)

      {:ok, fresh, _html} = live(context.conn, path)
      assert has_element?(fresh, "#stop-set-summary", "No stops approved")
      assert assigns(fresh).stop_set == nil
    end

    test "a version with no stops offers no form", %{conn: conn, organization: organization} do
      empty = gtfs_version_fixture(organization.id)
      {:ok, view, _html} = live(conn, ~p"/gtfs/#{empty.id}/stops")

      refute has_element?(view, "#stop-set-section")
    end
  end

  describe "forged events" do
    test "a choice must name a held candidate of that ambiguity, by stop ID", context do
      view = open_form(context)
      find(view, @mixed)
      stops = context.stops

      for params <- [
            # A resolved stop and a stop of the same version that is not a candidate.
            %{"ref" => "0", "stop" => "S410"},
            %{"ref" => "0", "stop" => "S700"},
            # A UUID in place of a stop ID, even of a real candidate.
            %{"ref" => "0", "stop" => stops["S601"].id},
            # An index outside the ambiguities, negative or not a number.
            %{"ref" => "1", "stop" => "S601"},
            %{"ref" => "-1", "stop" => "S601"},
            %{"ref" => "0.5", "stop" => "S601"},
            %{"ref" => "x", "stop" => "S601"},
            %{"ref" => 0, "stop" => "S601"},
            %{"stop" => "S601"},
            %{}
          ] do
        render_hook(view, "stop_set_choose", params)
        assert assigns(view).stop_set_resolution.choices == %{}
      end

      for params <- [%{"ref" => "1"}, %{"ref" => "-1"}, %{"ref" => "x"}, %{"ref" => 0}, %{}] do
        render_hook(view, "stop_set_skip", params)
        assert assigns(view).stop_set_resolution.choices == %{}
      end

      assert has_element?(view, "#stop-set-approve[disabled]")
    end

    test "approving with no resolution or an open ambiguity approves nothing", context do
      view = open_form(context)

      render_hook(view, "stop_set_approve", %{})
      assert assigns(view).stop_set == nil
      refute has_element?(view, "#stop-set-notice")

      find(view, @mixed)
      render_hook(view, "stop_set_approve", %{})

      assert assigns(view).stop_set == nil
      assert has_element?(view, "#stop-set-notice", "Choose a stop or skip 1 line first.")
    end

    test "a missing or malformed form changes nothing", context do
      view = open_form(context)

      render_hook(view, "stop_set_find", %{})
      render_hook(view, "stop_set_find", %{"stop_set" => %{"refs" => 5}})
      render_hook(view, "stop_set_change", %{"stop_set" => %{"refs" => nil}})

      assert assigns(view).stop_set_resolution == nil
      assert assigns(view).stop_set == nil
      assert has_element?(view, "#stop-set-form")
    end
  end
end
