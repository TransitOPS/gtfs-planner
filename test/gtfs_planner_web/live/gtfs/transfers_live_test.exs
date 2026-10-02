defmodule GtfsPlannerWeb.Gtfs.TransfersLiveTest do
  use GtfsPlannerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Mox
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.TransfersFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Gtfs.CatalogReadAdapter
  alias GtfsPlanner.Gtfs.CatalogReadAdapterMock
  alias GtfsPlanner.Versions

  @adapter_key :gtfs_catalog_read_adapter

  setup :verify_on_exit!

  # The real context serves every successful load; the adapter substitution
  # exists only to simulate a lost database connection, and is restored on exit.
  defp substitute_read_adapter(_context) do
    previous = Application.fetch_env(:gtfs_planner, @adapter_key)
    Application.put_env(:gtfs_planner, @adapter_key, CatalogReadAdapterMock)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:gtfs_planner, @adapter_key, value)
        :error -> Application.delete_env(:gtfs_planner, @adapter_key)
      end
    end)

    :ok
  end

  defp editor_setup(%{conn: conn}) do
    organization = organization_fixture()
    user = user_fixture()

    Accounts.create_user_org_membership(%{
      user_id: user.id,
      organization_id: organization.id,
      roles: ["pathways_studio_editor"]
    })

    version = gtfs_version_fixture(organization.id)

    %{
      conn: log_in_user(conn, user, organization: organization),
      user: user,
      organization: organization,
      version: version
    }
  end

  defp member_with_roles(organization, roles) do
    member = user_fixture()

    Accounts.create_user_org_membership(%{
      user_id: member.id,
      organization_id: organization.id,
      roles: roles
    })

    member
  end

  defp transfers_path(version), do: "/gtfs/#{version.id}/transfers"

  defp doc(view), do: LazyHTML.from_fragment(render(view))

  defp text_of(document, selector) do
    document |> LazyHTML.query(selector) |> LazyHTML.text() |> String.trim()
  end

  describe "page shell" do
    setup :editor_setup

    test "an editor sees the Transfers shell as the Routes area's second tab",
         %{conn: conn, organization: organization, version: version} do
      transfer_network_fixture(organization.id, version.id)

      transfer_fixture(organization.id, version.id, %{
        from_stop_id: "CEN-A",
        to_stop_id: "CEN-C"
      })

      {:ok, view, _html} = live(conn, transfers_path(version))

      assert has_element?(view, "#transfers-page")

      document = doc(view)

      assert Enum.count(LazyHTML.query(document, "h1")) == 1
      assert text_of(document, "h1") == "Transfers"

      assert text_of(document, "#transfers-page header p") ==
               "Rules that tell trip planners where riders can change routes, how much time they need, and where a connection won’t work."

      assert Enum.count(LazyHTML.query(document, "#routes-tabs a")) == 2

      assert LazyHTML.attribute(
               LazyHTML.query(document, "#routes-tabs a[aria-current='page']"),
               "href"
             ) == ["/gtfs/#{version.id}/transfers"]

      assert Enum.empty?(LazyHTML.query(document, "#coming-soon, #coming-soon-status"))

      # The workspace shell is one bordered container with both panes, and a
      # loaded version with rules is not a first-use version.
      assert has_element?(view, "section[aria-label='Transfer rules']")
      assert has_element?(view, "section[aria-label='Connection preview']")
      refute has_element?(view, "#transfers-first-use")
      refute has_element?(view, "#transfers-unavailable")
    end

    test "the context pane invites a choice before any connection is selected",
         %{conn: conn, organization: organization, version: version} do
      transfer_network_fixture(organization.id, version.id)

      {:ok, view, _html} = live(conn, transfers_path(version))

      assert has_element?(view, "#transfer-inspector-empty", "Connections appear here")

      assert has_element?(
               view,
               "#transfer-inspector-empty",
               "Each rule you add appears here on the map, with what it means for riders and trip planners."
             )
    end

    test "a version without general rules shows first use",
         %{conn: conn, version: version} do
      {:ok, view, _html} = live(conn, transfers_path(version))

      assert has_element?(view, "#transfers-first-use")
      refute has_element?(view, "#transfers-unavailable")

      document = doc(view)

      assert text_of(document, "#transfers-first-use") =~ "Most connections need no rule"

      assert text_of(document, "#transfers-first-use") =~
               "Trip planners already work out transfers from stop distance and timetables."

      # The panel carries the one create action, so the header has none.
      assert has_element?(view, "#transfers-first-use-create", "Create transfer rule")
      refute has_element?(view, "#transfers-create")
    end

    test "in-seat rows alone still show first use, because they are not general rules",
         %{conn: conn, organization: organization, version: version} do
      transfer_network_fixture(organization.id, version.id)

      transfer_fixture(organization.id, version.id, %{
        transfer_type: 4,
        from_trip_id: "12-0815",
        to_trip_id: "24-0840"
      })

      {:ok, view, _html} = live(conn, transfers_path(version))

      assert has_element?(view, "#transfers-first-use")
      refute has_element?(view, "#transfers-unavailable")
    end

    test "a page with no general rules and no in-seat rows shows the same first-use state",
         %{conn: conn, organization: organization, version: version} do
      transfer_network_fixture(organization.id, version.id)

      {:ok, view, _html} = live(conn, transfers_path(version))

      assert has_element?(view, "#transfers-first-use")
    end

    test "a lost catalog connection shows the load failure and its retry restores the workspace",
         %{conn: conn, organization: organization, version: version} do
      substitute_read_adapter(%{})

      transfer_network_fixture(organization.id, version.id)

      transfer_fixture(organization.id, version.id, %{
        from_stop_id: "CEN-A",
        to_stop_id: "CEN-C"
      })

      # The static render and the connected mount both load, so the first two
      # calls fail and the retry recovers.
      call_count = :atomics.new(1, [])

      stub(CatalogReadAdapterMock, :load_transfer_catalog, fn org, ver, opts ->
        if :atomics.add_get(call_count, 1, 1) <= 2 do
          {:error, :unavailable}
        else
          CatalogReadAdapter.Repo.load_transfer_catalog(org, ver, opts)
        end
      end)

      {:ok, view, _html} = live(conn, transfers_path(version))

      assert has_element?(view, "#transfers-unavailable", "Transfers couldn’t load")

      assert has_element?(
               view,
               "#transfers-unavailable",
               "Your rules haven’t changed. Try loading #{version.name} again."
             )

      assert has_element?(view, "#transfers-retry", "Retry loading")

      # The heading and the list pane stand behind the state, and the list pane
      # takes the whole card: a context pane that describes no rule has nothing
      # to say.
      assert has_element?(view, "#transfers-page")
      assert has_element?(view, "section[aria-label='Transfer rules']")
      refute has_element?(view, "section[aria-label='Connection preview']")
      refute has_element?(view, "#transfer-inspector-empty")
      refute has_element?(view, "#transfers-first-use")
      refute has_element?(view, "#transfers-create")

      view |> element("#transfers-retry") |> render_click()

      refute has_element?(view, "#transfers-unavailable")
      refute has_element?(view, "#transfers-first-use")
      assert has_element?(view, "section[aria-label='Transfer rules']")
      assert has_element?(view, "section[aria-label='Connection preview']")
      assert has_element?(view, "#transfers-create")
      assert has_element?(view, "#transfers-page")
    end
  end

  describe "the pane that has the screen below 1024px" do
    setup :editor_setup

    test "the list has it until the URL names a rule, then the rule does", ctx do
      transfer_network_fixture(ctx.organization.id, ctx.version.id)

      first =
        transfer_fixture(ctx.organization.id, ctx.version.id, %{
          from_stop_id: "CEN-A",
          to_stop_id: "CEN-C"
        })

      {:ok, view, _html} = live(ctx.conn, transfers_path(ctx.version))

      # The first rule is selected (and drawn on a wide screen) without being named
      # in the URL, so it does not take a phone's screen from the list.
      assert has_element?(view, "#transfers-workspace[data-detail='closed']")
      assert has_element?(view, "#transfer-select-#{first.id}[aria-current='true']")

      view |> element("#transfer-select-#{first.id}") |> render_click()

      assert has_element?(view, "#transfers-workspace[data-detail='open']")

      # The way back patches to the same list without the rule.
      assert has_element?(
               view,
               "#transfer-inspector-back[href='#{transfers_path(ctx.version)}']",
               "All transfer rules"
             )

      view |> element("#transfer-inspector-back") |> render_click()

      assert_patched(view, transfers_path(ctx.version))
      assert has_element?(view, "#transfers-workspace[data-detail='closed']")
    end

    test "the editor shows its form over its preview, and a pick gives the map the screen",
         ctx do
      transfer_network_fixture(ctx.organization.id, ctx.version.id)

      {:ok, view, _html} = live(ctx.conn, transfers_path(ctx.version))

      view |> element("#transfers-first-use-create") |> render_click()
      assert has_element?(view, "#transfers-workspace[data-detail='both']")

      view |> element("#transfer-pick-from") |> render_click()
      assert has_element?(view, "#transfers-workspace[data-detail='open']")

      view |> element("#transfer-pick-cancel") |> render_click()
      assert has_element?(view, "#transfers-workspace[data-detail='both']")
    end

    test "a failed load gives the list the whole card", ctx do
      substitute_read_adapter(%{})

      stub(CatalogReadAdapterMock, :load_transfer_catalog, fn _org, _ver, _opts ->
        {:error, :unavailable}
      end)

      {:ok, view, _html} = live(ctx.conn, transfers_path(ctx.version))

      assert has_element?(view, "#transfers-workspace[data-detail='none']")
    end
  end

  describe "version switching" do
    setup :editor_setup

    test "an explicit selection keeps Transfers in the new version",
         %{conn: conn, organization: organization, version: version} do
      {:ok, other_version} =
        Versions.create_gtfs_version(organization.id, %{name: "Second Version"})

      {:ok, view, _html} = live(conn, transfers_path(version))
      selected_version_id = to_string(other_version.id)

      render_hook(view, "switch_gtfs_version", %{"version" => selected_version_id})

      assert_push_event(view, "gtfs_version_selected", %{version_id: ^selected_version_id})

      assert_redirect(view, transfers_path(other_version))
    end

    test "staging, foreign and absent selections neither navigate nor report a selection",
         %{conn: conn, organization: organization, version: version} do
      {:ok, staging} = Versions.create_staging_gtfs_version(organization.id, %{name: "Staging"})

      other_organization = organization_fixture()
      foreign_version = gtfs_version_fixture(other_organization.id)

      {:ok, view, _html} = live(conn, transfers_path(version))

      for version_id <- [staging.id, foreign_version.id, Ecto.UUID.generate()] do
        render_hook(view, "switch_gtfs_version", %{"version" => to_string(version_id)})
        refute_push_event(view, "gtfs_version_selected", %{version_id: _})
        refute_redirected(view)
      end
    end

    test "a stored selection navigates to Transfers in the new version",
         %{conn: conn, organization: organization, version: version} do
      {:ok, other_version} =
        Versions.create_gtfs_version(organization.id, %{name: "Second Version"})

      {:ok, view, _html} = live(conn, transfers_path(version))

      render_hook(view, "gtfs_version_loaded", %{"version_id" => to_string(other_version.id)})

      assert_redirect(view, transfers_path(other_version))
      refute_push_event(view, "gtfs_version_selected", %{version_id: _})
    end

    test "a stored selection of the current version changes nothing",
         %{conn: conn, version: version} do
      {:ok, view, _html} = live(conn, transfers_path(version))

      for version_id <- [to_string(version.id), nil] do
        render_hook(view, "gtfs_version_loaded", %{"version_id" => version_id})
        refute_redirected(view)
      end
    end
  end

  describe "list pagination" do
    setup :editor_setup

    test "a forged paginate event with integer page 3 shows page 3", %{
      conn: conn,
      organization: organization,
      version: version
    } do
      transfers =
        for index <- 1..101 do
          transfer_fixture(organization.id, version.id, %{
            from_stop_id: "P" <> String.pad_leading(Integer.to_string(index), 3, "0"),
            to_stop_id: "P000"
          })
        end

      first = List.first(transfers)
      last = List.last(transfers)

      {:ok, view, _html} = live(conn, transfers_path(version))

      assert has_element?(view, "#transfer-select-#{first.id}")
      refute has_element?(view, "#transfer-select-#{last.id}")

      view |> render_hook("paginate", %{"page" => 3})

      assert_patched(view, transfers_path(version) <> "?page=3")
      assert has_element?(view, "#transfer-select-#{last.id}")
      refute has_element?(view, "#transfer-select-#{first.id}")
    end
  end

  describe "access" do
    setup :editor_setup

    test "members without the editor role cannot reach Transfers",
         %{conn: conn, organization: organization, version: version} do
      for roles <- [[], ["pathways_studio_admin"]] do
        member = member_with_roles(organization, roles)
        member_conn = log_in_user(conn, member, organization: organization)

        assert {:error, {:redirect, %{to: "/admin/organizations"}}} =
                 live(member_conn, transfers_path(version))
      end
    end

    test "unauthenticated visits follow the existing login redirect", %{version: version} do
      conn = build_conn() |> init_test_session(%{})

      assert redirected_to(get(conn, transfers_path(version))) == "/users/log_in"
    end
  end
end
