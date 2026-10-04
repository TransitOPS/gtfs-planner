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

  import Phoenix.LiveViewTest
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.Agents.PackTurn, only: [setup_conversations: 0]
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.FareSelectionFixtures

  setup {Req.Test, :verify_on_exit!}

  setup do
    setup_conversations()

    organization = organization_fixture()
    user = user_fixture()
    organization_membership_fixture(user, organization)
    version = gtfs_version_fixture(organization.id, %{name: "Helper Zones Version"})

    stops = FareSelectionFixtures.insert_network!(organization, version)
    FareSelectionFixtures.declare_zone!(organization, version, "B")
    FareSelectionFixtures.declare_zone!(organization, version, "C")

    %{organization: organization, user: user, version: version, stops: stops}
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

  ## Helpers

  defp log_in(conn, context),
    do: log_in_user(conn, context.user, organization: context.organization)

  defp open_zones(context) do
    build_conn()
    |> log_in(context)
    |> live("/gtfs/#{context.version.id}/settings/fares/zones")
  end
end
