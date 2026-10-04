defmodule GtfsPlannerWeb.Gtfs.StopMetadataApplyLiveTest do
  @moduledoc """
  Merge evidence (EV-27) for saving a reviewed stop batch from the real stops catalog.

  The batch is prepared by the real session with only the provider's HTTP boundary
  scripted, reviewed in the page's drawer and saved through the native batch with the
  review's fingerprint. Expected values are written by hand from the fixture:

    * `S410` Elm Street Station, code `E-1`, `Elm Street`'s neighbour on 40.7128, -74.0060
    * `S411` Pine Plaza, code `P-1`
    * `S412` Oak Court, approved but never in a batch
  """

  use GtfsPlannerWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures
  import GtfsPlannerWeb.HeadsignHelperLiveHelpers, only: [assigns: 1]
  import GtfsPlannerWeb.StopTextHelperLiveHelpers
  import Phoenix.LiveViewTest

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Agents.ScriptedProvider
  alias GtfsPlanner.Gtfs.ChangeLog
  alias GtfsPlanner.Gtfs.Stop
  alias GtfsPlanner.Repo

  @batch [
    %{"stop_id" => "S410", "stop_name" => "Elm Street", "stop_code" => "E-2"},
    %{"stop_id" => "S411", "stop_name" => "Pine Square"}
  ]

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
      for {stop_id, name, code} <- [
            {"S410", "Elm Street Station", "E-1"},
            {"S411", "Pine Plaza", "P-1"},
            {"S412", "Oak Court", nil}
          ],
          into: %{} do
        stop = stop_fixture(organization.id, version.id, %{stop_id: stop_id, stop_name: name})
        set_stop(stop, stop_code: code)
        {stop_id, stop}
      end

    %{
      conn: log_in_user(conn, user, organization: organization),
      user: user,
      membership: membership,
      organization: organization,
      version: version,
      stops: stops
    }
  end

  setup {Req.Test, :verify_on_exit!}

  describe "saving" do
    test "writes only the four fields, audits each stop, refreshes the catalog and confirms the card",
         context do
      {view, entry} = prepared_view(context, @batch)
      view |> element("#agent-review-prepared-#{entry}") |> render_click()
      untouched = untouched_fields()

      view |> element("#stop-review-save") |> render_click()

      %{"S410" => elm, "S411" => pine, "S412" => oak} = context.stops
      assert {Repo.reload!(elm).stop_name, Repo.reload!(elm).stop_code} == {"Elm Street", "E-2"}
      assert Repo.reload!(pine).stop_name == "Pine Square"
      assert Repo.reload!(oak).stop_name == "Oak Court"

      # Nothing but the four text fields changed, on any stop.
      assert untouched_fields() == untouched

      logs = stop_logs(context)
      assert Enum.sort(Enum.map(logs, & &1.entity_id)) == Enum.sort([elm.id, pine.id])
      assert Enum.all?(logs, &(&1.action == "updated" and &1.actor_id == context.user.id))

      refute has_element?(view, "#stop-review")
      assert has_element?(view, "#flash-info", "Saved 2 stops")
      assert has_element?(view, "#stops", "Elm Street")
      assert has_element?(view, "#stops", "Pine Square")
      assert has_element?(view, "#agent-prepared-#{entry}", "Applied")
      refute has_element?(view, "#agent-review-prepared-#{entry}")
      refute has_element?(view, "#agent-notice")

      # The approved list shows the saved names.
      assert has_element?(view, "#stop-set-list li[data-stop-id=\"S411\"]", "Pine Square")
    end

    test "a second save event finds no review and writes nothing more", context do
      {view, entry} = prepared_view(context, @batch)
      view |> element("#agent-review-prepared-#{entry}") |> render_click()

      view |> element("#stop-review-save") |> render_click()
      render_hook(view, "stop_review_save", %{})

      assert length(stop_logs(context)) == 2
      assert has_element?(view, "#agent-prepared-#{entry}", "Applied")
    end

    test "a stop changed by another session is refused as stale, then saves against the refreshed review",
         context do
      {view, entry} = prepared_view(context, @batch)
      view |> element("#agent-review-prepared-#{entry}") |> render_click()
      first = assigns(view).stop_review.review.fingerprint

      # Another editor renames S411 after the review; the stored content is part of the
      # fingerprint, so the save is stale even though `update_all` leaves `updated_at`.
      set_stop(context.stops["S411"], stop_name: "Renamed elsewhere")
      before = stamps()

      view |> element("#stop-review-save") |> render_click()

      assert has_element?(view, "#stop-review-notice", "changed since you reviewed them")
      assert has_element?(view, "#stop-review")
      assert stamps() == before
      assert stop_logs(context) == []

      # The drawer shows the value the database holds now, under a new fingerprint.
      assert has_element?(view, "#stop-review-table", "Renamed elsewhere")
      assert assigns(view).stop_review.review.fingerprint != first

      view |> element("#stop-review-save") |> render_click()

      assert Repo.reload!(context.stops["S411"]).stop_name == "Pine Square"
      assert length(stop_logs(context)) == 2
      refute has_element?(view, "#stop-review")
    end
  end

  describe "refusals" do
    test "an invalid row disables Save with its reason and a forged save writes nothing",
         context do
      {view, entry} = prepared_view(context, @batch)
      set_stop(context.stops["S410"], stop_lat: nil, stop_lon: nil)
      view |> element("#agent-review-prepared-#{entry}") |> render_click()
      before = stamps()

      assert has_element?(view, "#stop-review-save[disabled]")
      assert has_element?(view, "#stop-review-save-reason", "Fix the stops with errors")

      render_hook(view, "stop_review_save", %{})

      assert stamps() == before
      assert stop_logs(context) == []
      assert has_element?(view, "#stop-review")
    end

    test "a revoked editor keeps the review with the access notice and writes nothing",
         context do
      {view, entry} = prepared_view(context, @batch)
      view |> element("#agent-review-prepared-#{entry}") |> render_click()
      before = stamps()
      deactivate_membership_fixture(context.membership)

      view |> element("#stop-review-save") |> render_click()

      assert has_element?(view, "#stop-review")
      assert has_element?(view, "#stop-review-notice", "Your access changed.")
      assert stamps() == before
      assert stop_logs(context) == []
      refute has_element?(view, "#agent-prepared-#{entry}", "Applied")
    end

    test "a stop deleted after review closes the drawer with the not-found notice", context do
      {view, entry} = prepared_view(context, @batch)
      view |> element("#agent-review-prepared-#{entry}") |> render_click()

      stop_uuid = context.stops["S411"].id
      Repo.delete_all(from(s in Stop, where: s.id == ^stop_uuid))
      before = stamps()

      view |> element("#stop-review-save") |> render_click()

      refute has_element?(view, "#stop-review")

      assert has_element?(
               view,
               "#agent-notice",
               "One of these stops is no longer in this service version. Approve the stops again."
             )

      assert stamps() == before
      assert stop_logs(context) == []
    end
  end

  describe "the card's receipt" do
    test "a batch with fewer changed rows than prepared saves but leaves the card unconfirmed",
         context do
      {view, entry} = prepared_view(context, @batch)

      # S410 already has its prepared name and code by the time the editor reviews.
      set_stop(context.stops["S410"], stop_name: "Elm Street", stop_code: "E-2")
      view |> element("#agent-review-prepared-#{entry}") |> render_click()
      assert has_element?(view, "#stop-review-unchanged", "1 stop already has these values")

      view |> element("#stop-review-save") |> render_click()

      assert Repo.reload!(context.stops["S411"]).stop_name == "Pine Square"
      assert has_element?(view, "#flash-info", "Saved 1 stop")

      assert has_element?(
               view,
               "#agent-notice",
               "The saved changes differ from the prepared request, so the card stays unconfirmed."
             )

      refute has_element?(view, "#agent-prepared-#{entry}", "Applied")
    end
  end

  # -- helpers ----------------------------------------------------------------

  # Every stop's text, stamps and lock: what a refused save must not touch.
  defp stamps do
    Repo.all(
      from(s in Stop,
        order_by: s.id,
        select: {s.id, s.stop_name, s.stop_code, s.updated_at, s.lock_version}
      )
    )
  end

  # Everything about a stop except the four text fields a batch may write, and the
  # bookkeeping a save moves (`updated_at` and `lock_version`).
  defp untouched_fields do
    Repo.all(
      from(s in Stop,
        order_by: s.id,
        select:
          {s.id, s.stop_id, s.stop_lat, s.stop_lon, s.location_type, s.wheelchair_boarding,
           s.parent_station, s.zone_id, s.level_id}
      )
    )
  end

  defp stop_logs(context) do
    Repo.all(
      from(l in ChangeLog,
        where: l.organization_id == ^context.organization.id and l.entity_type == "stop",
        order_by: l.id
      )
    )
  end
end
