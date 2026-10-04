defmodule GtfsPlannerWeb.Gtfs.FareEditorHelperTest do
  @moduledoc """
  Merge evidence (EV-15) for the managed Prices tab's helper: the panel, the
  native price review opened from a prepared entry and the confirmed save.

  The page, the conversation session and the turn task are separate processes, so
  the SQL sandbox and the `Req.Test` plug are shared (`async: false`) and only the
  OpenRouter HTTP boundary is scripted. The version enters rows the way a user's
  version does (the production importer of `north_coast_v2` and the production
  conversion), and every expected price is a literal from that fixture.
  """
  use GtfsPlannerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.Agents.PackTurn, only: [setup_conversations: 0]
  import GtfsPlanner.FaresFixtures, only: [import!: 3, managed!: 3]
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  setup {Req.Test, :verify_on_exit!}

  setup do
    setup_conversations()

    organization = organization_fixture()
    user = user_fixture()
    membership = organization_membership_fixture(user, organization)
    version = gtfs_version_fixture(organization.id, %{name: "Helper Prices Version"})
    managed!(organization, version, user)

    %{organization: organization, user: user, membership: membership, version: version}
  end

  describe "the panel" do
    test "Open helper renders the panel with the fare price intro, and the grid still works",
         context do
      {:ok, view, _html} = open(context, context.version)

      assert has_element?(view, "#agent-helper-open", "Open helper")
      refute has_element?(view, "#agent-panel")

      view |> element("#agent-helper-open") |> render_click()

      assert has_element?(view, "#agent-panel")
      assert has_element?(view, "#agent-helper-open[aria-expanded=true]")
      assert has_element?(view, "#agent-panel", "Fare price helper")
      assert has_element?(view, "#agent-panel", "I can list this version's fare prices")
      assert has_element?(view, "#agent-example-1", "Raise the Local ride adult and reduced cash")
      assert_push_event(view, "agent:focus", %{id: "agent-composer-input"})

      view
      |> element("#fare-table-form")
      |> render_change(%{"price" => %{"local_ride_adult_cash|adult|cash" => "1.75"}})

      assert has_element?(view, "#fare-table-form")
      assert has_element?(view, "#create-fare")
    end

    test "the button is absent where the helper cannot work", context do
      for path <- ["/where", "/transfers", "/checks"] do
        {:ok, view, _html} = open_path(context, context.version, path)
        refute has_element?(view, "#agent-helper-open"), "tab #{path}"
      end

      # While loading: the static render has not loaded the workspace.
      static =
        build_conn()
        |> log_in(context)
        |> get("/gtfs/#{context.version.id}/settings/fares")

      refute html_response(static, 200) =~ "agent-helper-open"

      # An unmanaged version shows the read-only view and its conversion prompt.
      unmanaged = gtfs_version_fixture(context.organization.id, %{name: "Unmanaged Prices"})
      import!(context.organization, unmanaged, "north_coast_v1")
      {:ok, view, _html} = open(context, unmanaged)

      assert has_element?(view, "#unmanaged-fares")
      refute has_element?(view, "#agent-helper-open")

      # A version with no fares is in the first-use setup.
      blank = gtfs_version_fixture(context.organization.id, %{name: "Blank Prices"})
      import!(context.organization, blank, "no_fare")
      {:ok, view, _html} = open(context, blank)

      assert has_element?(view, "#fare-setup")
      refute has_element?(view, "#agent-helper-open")
    end

    test "a panel left open does not follow the editor to another tab", context do
      {:ok, view, _html} = open(context, context.version)
      view |> element("#agent-helper-open") |> render_click()
      assert has_element?(view, "#agent-panel")

      {:ok, view, _html} = open_path(context, context.version, "/where")
      refute has_element?(view, "#agent-panel")
    end
  end

  ## Helpers

  defp log_in(conn, context),
    do: log_in_user(conn, context.user, organization: context.organization)

  defp open(context, version), do: open_path(context, version, "")

  defp open_path(context, version, suffix) do
    build_conn()
    |> log_in(context)
    |> live("/gtfs/#{version.id}/settings/fares#{suffix}")
  end
end
