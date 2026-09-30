defmodule GtfsPlannerWeb.Gtfs.BlocksConnectionsViewLiveTest do
  # The Connections view's own page state: the third option of `#blocks-view`, the
  # URL parameters that view reads and emits, and the derived assigns those
  # parameters produce. Observed through the ordinary `/gtfs/:version/blocks`
  # route on the production `CatalogReadAdapter.Repo` and the scoped `Blocking`
  # context, so the groups under the filters are the ones
  # `Blocking.Connections` derived from the loaded day.
  #
  # The day is one block of two consecutive trips meeting at one stop on two
  # routes, so it holds exactly one group and one connection — enough for the
  # filters, the group token and the counts to be observed without a fixture big
  # enough to page.
  use GtfsPlannerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.BlockingFixtures
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Gtfs.Blocking.Connections

  @weekday_dates [~D[2026-09-01], ~D[2026-09-02], ~D[2026-09-03]]

  setup do
    organization = organization_fixture()
    user = user_fixture()

    Accounts.create_user_org_membership(%{
      user_id: user.id,
      organization_id: organization.id,
      roles: ["pathways_studio_editor"]
    })

    version = gtfs_version_fixture(organization.id)

    twelve =
      route_fixture(organization.id, version.id, %{route_id: "R12", route_short_name: "12"})

    twenty_four =
      route_fixture(organization.id, version.id, %{route_id: "R24", route_short_name: "24"})

    # A route the version carries but no connection runs on, so a Route filter
    # can narrow to none without the page clearing an unknown route instead.
    lonely =
      route_fixture(organization.id, version.id, %{route_id: "R50", route_short_name: "50"})

    calendar_service_fixture(organization.id, version.id, %{
      service_id: "W",
      name: "Weekday",
      dates: @weekday_dates
    })

    main =
      GtfsPlanner.GtfsFixtures.stop_fixture(organization.id, version.id, %{
        stop_id: "CONN_VIEW_#{System.unique_integer([:positive])}",
        stop_name: "Main St",
        stop_lat: Decimal.new("40.0200"),
        stop_lon: Decimal.new("-74.0000")
      })

    a =
      blocked_trip_fixture(organization.id, version.id, twelve.route_id, %{
        service_id: "W",
        trip_id: "a",
        block_id: "101",
        first_stop: main.stop_id,
        last_stop: main.stop_id,
        first_arrival: "06:00:00",
        last_arrival: "07:00:00"
      })

    blocked_trip_fixture(organization.id, version.id, twenty_four.route_id, %{
      service_id: "W",
      trip_id: "b",
      block_id: "101",
      first_stop: main.stop_id,
      last_stop: main.stop_id,
      first_arrival: "07:10:00",
      last_arrival: "08:10:00"
    })

    %{
      organization: organization,
      user: user,
      version: version,
      from: a,
      route_twelve: twelve,
      route_twenty_four: twenty_four,
      route_lonely: lonely
    }
  end

  defp blocks_path(version_id), do: "/gtfs/#{version_id}/blocks"

  defp editor_conn(context) do
    log_in_user(context.conn, context.user, organization: context.organization)
  end

  defp connections_url(version_id, params) do
    blocks_path(version_id) <> "?" <> URI.encode_query(params)
  end

  defp mount_blocks(context, params \\ []) do
    path =
      if params == [],
        do: blocks_path(context.version.id),
        else: connections_url(context.version.id, params)

    live(editor_conn(context), path)
  end

  # The one group the seeded day derives, read through the same production
  # derivation the view reads rather than from a token this test guesses.
  defp group_token(context) do
    {:ok, day} =
      GtfsPlanner.Gtfs.load_blocking_day(
        context.organization.id,
        context.version.id,
        nil
      )

    %{groups: [group | _rest]} = Connections.build(day)
    group.token
  end

  describe "the view control" do
    test "Connections is offered beside Timeline and List and patches its own parameter",
         context do
      {:ok, view, _html} = mount_blocks(context)

      assert has_element?(view, "#blocks-view-option-connections")

      assert view
             |> element("#blocks-view-form")
             |> render_change(%{"view" => "connections"}) =~ "Connections"

      assert_patch(view, connections_url(context.version.id, view: "connections"))
      assert has_element?(view, "#connections-panel")
    end

    test "Connections is the pressed option once its parameter is in the URL", context do
      {:ok, view, _html} = mount_blocks(context, view: "connections")

      assert has_element?(view, "#blocks-view-option-connections[checked]")
    end

    test "the timeline scale control is hidden in the Connections view", context do
      {:ok, timeline, _html} = mount_blocks(context)

      assert has_element?(timeline, "#blocks-scale")

      {:ok, connections, _html} = mount_blocks(context, view: "connections")

      refute has_element?(connections, "#blocks-scale")
    end
  end

  describe "the filter form's event" do
    test "a Show filter patches setting=review and drops the group and the page", context do
      token = group_token(context)

      {:ok, view, _html} =
        mount_blocks(context, view: "connections", group: token, gpage: "2", cq: "101")

      render_hook(view, "filter_connections", %{"setting" => "review", "cq" => "", "route" => ""})

      assert_patch(
        view,
        connections_url(context.version.id, view: "connections", setting: "review")
      )
    end

    test "the Find and Route filters patch their own parameters", context do
      {:ok, view, _html} = mount_blocks(context, view: "connections")

      render_hook(view, "filter_connections", %{
        "setting" => "",
        "cq" => "block 101",
        "route" => context.route_twelve.route_id
      })

      assert_patch(
        view,
        connections_url(context.version.id,
          view: "connections",
          route: context.route_twelve.route_id,
          cq: "block 101"
        )
      )
    end

    test "an unknown Show value widens the list rather than emptying it", context do
      {:ok, view, _html} = mount_blocks(context, view: "connections")

      render_hook(view, "filter_connections", %{
        "setting" => "sideways",
        "cq" => "",
        "route" => ""
      })

      assert_patch(view, connections_url(context.version.id, view: "connections"))
      assert has_element?(view, "#connections-summary", "1 of 1 connection at 1 place")
    end
  end

  describe "the group token" do
    test "opening and closing a group patches the group parameter", context do
      token = group_token(context)

      {:ok, view, _html} = mount_blocks(context, view: "connections")

      render_hook(view, "open_group", %{"group" => token})

      assert_patch(view, connections_url(context.version.id, view: "connections", group: token))

      render_hook(view, "close_group", %{})

      assert_patch(view, connections_url(context.version.id, view: "connections"))
    end

    test "a token the day does not hold renders the list without an error", context do
      {:ok, view, _html} =
        mount_blocks(context,
          view: "connections",
          group: Base.url_encode64("no-such-group", padding: false)
        )

      assert has_element?(view, "#connections-panel")
      assert has_element?(view, "#connections-summary", "1 of 1 connection at 1 place")
    end
  end

  describe "the derived assigns" do
    test "the summary counts the filtered connections at the day's places", context do
      {:ok, view, _html} = mount_blocks(context, view: "connections")

      assert has_element?(view, "#connections-summary", "1 of 1 connection at 1 place")
    end

    test "a search no connection matches reports none of them", context do
      {:ok, view, _html} = mount_blocks(context, view: "connections", cq: "nowhere")

      assert has_element?(view, "#connections-summary", "0 of 1 connection at 0 places")
    end

    test "a route filter no connection runs on reports none of them", context do
      {:ok, view, _html} =
        mount_blocks(context, view: "connections", route: context.route_lonely.route_id)

      assert has_element?(view, "#connections-summary", "0 of 1 connection at 0 places")
    end
  end

  describe "quiet URLs" do
    test "a default URL carries none of the view's parameters", context do
      {:ok, view, _html} = mount_blocks(context)

      render_hook(view, "set_view", %{"view" => "timeline"})

      assert_patch(view, blocks_path(context.version.id))
    end

    test "clearing every Connections filter leaves only the view parameter", context do
      token = group_token(context)

      {:ok, view, _html} =
        mount_blocks(context,
          view: "connections",
          group: token,
          gpage: "1",
          cq: "101",
          setting: "review"
        )

      render_hook(view, "filter_connections", %{"setting" => "", "cq" => "", "route" => ""})

      assert_patch(view, connections_url(context.version.id, view: "connections"))
    end

    test "the group page is emitted only when it is not the first", context do
      {:ok, view, _html} = mount_blocks(context, view: "connections")

      render_hook(view, "filter_connections", %{"setting" => "", "cq" => "", "route" => ""})

      assert_patch(view, connections_url(context.version.id, view: "connections"))
    end
  end
end
