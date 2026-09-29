defmodule GtfsPlannerWeb.NavigationComponentsTest do
  use GtfsPlannerWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Phoenix.Component
  import GtfsPlannerWeb.CoreComponents

  alias GtfsPlanner.Organizations.Organization
  alias GtfsPlannerWeb.Layouts
  alias GtfsPlannerWeb.Navigation

  defp render_nav(assigns) do
    rendered_to_string(~H"""
    <Navigation.top_nav
      current_user={@current_user}
      current_organization={@current_organization}
      user_roles={@user_roles}
      current_path={@current_path}
      current_gtfs_version={@current_gtfs_version}
    />
    """)
  end

  defp render_user_menu(assigns) do
    assigns =
      Map.merge(
        %{
          current_user: editor_user(),
          current_path: "/",
          current_organization: nil,
          user_roles: [],
          current_gtfs_version: nil
        },
        assigns
      )

    rendered_to_string(~H"""
    <Navigation.user_menu
      current_user={@current_user}
      current_path={@current_path}
      current_organization={@current_organization}
      user_roles={@user_roles}
      current_gtfs_version={@current_gtfs_version}
    />
    """)
  end

  defp editor_menu_assigns(path), do: %{current_user: editor_user(), current_path: path}

  defp menu_doc(overrides) do
    LazyHTML.from_fragment(render_user_menu(Map.merge(editor_menu_assigns("/"), overrides)))
  end

  defp editor_menu_context(path) do
    %{
      current_path: path,
      current_organization: org(),
      user_roles: ["pathways_studio_editor"],
      current_gtfs_version: gtfs_version()
    }
  end

  defp admin_user,
    do: %GtfsPlanner.Accounts.UserOrgMembership{roles: ["administrator"]}

  defp editor_user, do: %{id: 2, email: "editor@test.com"}

  defp org, do: %{id: 1, name: "Test Org"}

  defp gtfs_version, do: %{id: 42, name: "v1"}

  defp admin_assigns(path) do
    %{
      current_user: admin_user(),
      current_organization: org(),
      user_roles: ["pathways_studio_admin", "pathways_studio_editor"],
      current_path: path,
      current_gtfs_version: gtfs_version()
    }
  end

  defp editor_assigns(path) do
    %{
      current_user: editor_user(),
      current_organization: org(),
      user_roles: ["pathways_studio_editor"],
      current_path: path,
      current_gtfs_version: gtfs_version()
    }
  end

  defp org_admin_assigns(path) do
    %{
      current_user: editor_user(),
      current_organization: org(),
      user_roles: ["pathways_studio_admin"],
      current_path: path,
      current_gtfs_version: gtfs_version()
    }
  end

  defp no_task_assigns(path) do
    %{
      current_user: editor_user(),
      current_organization: org(),
      user_roles: [],
      current_path: path,
      current_gtfs_version: nil
    }
  end

  defp account_link(doc) do
    LazyHTML.query(doc, ~s(a[href="/users/settings"]))
  end

  defp nav_link_texts(html) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("nav[aria-label='Main navigation'] a")
    |> Enum.map(&String.trim(LazyHTML.text(&1)))
  end

  defp sub_nav_links(html, nav_id) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("##{nav_id} a")
  end

  defp sub_nav_texts(links), do: Enum.map(links, &String.trim(LazyHTML.text(&1)))

  defp sub_nav_attr(links, name), do: LazyHTML.attribute(links, name)

  defp current_sub_nav_links(links) do
    Enum.filter(links, &(LazyHTML.attribute(&1, "aria-current") == ["page"]))
  end

  # The contract every area bar shares: ordinary links with the underline/focus
  # presentation, unique stable IDs, exactly one current link, and horizontal
  # scrolling contained by the bar itself. Page padding lives on the
  # sub-header wrapper (mirroring the header and main column), so the bar
  # itself carries no horizontal padding.
  defp assert_sub_nav_contract(html, nav_id) do
    doc = LazyHTML.from_fragment(html)
    links = LazyHTML.query(doc, "##{nav_id} a")

    refute Enum.empty?(links)
    assert Enum.empty?(LazyHTML.query(doc, "##{nav_id} [role=\"tablist\"]"))
    assert Enum.empty?(LazyHTML.query(doc, "##{nav_id} [role=\"tab\"]"))
    refute html =~ "aria-selected"

    ids = sub_nav_attr(links, "id")
    assert Enum.count(ids) == Enum.count(links)
    assert Enum.uniq(ids) == ids

    for class <- sub_nav_attr(links, "class") do
      assert class =~ "min-h-11"
      assert class =~ "border-b-2"
      assert class =~ "focus-visible:ring-2"
    end

    nav_class = LazyHTML.attribute(LazyHTML.query(doc, "##{nav_id}"), "class") |> List.first()
    refute nav_class =~ "px-4"

    scrollable =
      doc
      |> LazyHTML.query("##{nav_id} > *")
      |> LazyHTML.attribute("class")
      |> Enum.any?(&(&1 =~ "overflow-x-auto"))

    assert scrollable, "expected a locally scrolling container inside ##{nav_id}"
  end

  describe "top_nav excludes account actions" do
    test "task navigation omits the Profile settings link" do
      html = render_nav(admin_assigns("/"))
      doc = LazyHTML.from_fragment(html)

      assert Enum.empty?(account_link(doc))
      refute html =~ "hero-cog-6-tooth"
    end

    test "editor sees gated GTFS tasks and no account link" do
      html = render_nav(editor_assigns("/"))
      doc = LazyHTML.from_fragment(html)

      assert Enum.empty?(account_link(doc))
      assert html =~ "Routes"
      assert "Stops & stations" in nav_link_texts(html)
      refute html =~ "Organizations"
    end

    test "organization admin sees no task link and no Organizations link" do
      html = render_nav(org_admin_assigns("/"))
      doc = LazyHTML.from_fragment(html)

      assert Enum.empty?(account_link(doc))
      assert nav_link_texts(html) == []
      refute html =~ "Users"
      refute html =~ "Organizations"
    end

    test "no-task role sees an empty task nav" do
      html = render_nav(no_task_assigns("/"))

      assert nav_link_texts(html) == []
    end

    test "declared visual order lists the six task links and then Organizations" do
      texts = nav_link_texts(render_nav(editor_assigns("/")))

      assert texts == [
               "Routes",
               "Calendars",
               "Operations",
               "Stops & stations",
               "Flex",
               "GTFS"
             ]

      assert nav_link_texts(render_nav(admin_assigns("/"))) == texts ++ ["Organizations"]
    end

    test "task links are labels only, without icons or the retired pills" do
      html = render_nav(editor_assigns("/"))
      doc = LazyHTML.from_fragment(html)

      assert Enum.empty?(LazyHTML.query(doc, "#main-navigation svg"))

      for retired <- ["Users", "Blocks", "Import", "Export"] do
        refute retired in nav_link_texts(html)
      end

      assert LazyHTML.attribute(LazyHTML.query(doc, "#nav-gtfs"), "href") == [
               "/gtfs/42/export"
             ]

      assert LazyHTML.attribute(LazyHTML.query(doc, "#nav-operations"), "href") == [
               "/gtfs/42/blocks"
             ]
    end

    test "Organizations follows a divider after the task links" do
      doc = LazyHTML.from_fragment(render_nav(admin_assigns("/")))
      nav = LazyHTML.query(doc, "#main-navigation")

      refute Enum.empty?(
               LazyHTML.query(doc, "#main-navigation span[aria-hidden='true'].bg-subtle")
             )

      # The divider is the element immediately before Organizations.
      assert String.trim(LazyHTML.text(LazyHTML.query(nav, "a:last-of-type"))) == "Organizations"
    end

    test "an editor without the administrator role has no divider" do
      doc = LazyHTML.from_fragment(render_nav(editor_assigns("/")))

      assert Enum.empty?(LazyHTML.query(doc, "#main-navigation span[aria-hidden='true']"))
    end
  end

  describe "user_menu account actions" do
    test "initial-trigger opens a menu, labeled with the signed-in email" do
      html = render_user_menu(editor_menu_assigns("/"))
      doc = LazyHTML.from_fragment(html)

      trigger = LazyHTML.query(doc, "[data-user-menu-trigger]")
      assert LazyHTML.attribute(trigger, "aria-haspopup") == ["menu"]
      assert LazyHTML.attribute(trigger, "aria-expanded") == ["false"]

      # The email is not visible header text; it rides in the accessible name.
      refute LazyHTML.text(trigger) =~ "editor@test.com"
      assert LazyHTML.attribute(trigger, "aria-label") |> List.first() =~ "editor@test.com"

      panel = LazyHTML.query(doc, "#user-menu-panel")
      assert LazyHTML.attribute(panel, "role") == ["menu"]
      # Identity is still shown once the menu is open.
      assert LazyHTML.text(panel) =~ "editor@test.com"
    end

    test "menu holds exactly one Profile settings item" do
      html = render_user_menu(editor_menu_assigns("/"))
      doc = LazyHTML.from_fragment(html)

      links = account_link(doc)
      assert Enum.count(links) == 1
      assert LazyHTML.text(links) =~ "Profile settings"
      assert LazyHTML.attribute(links, "role") == ["menuitem"]
    end

    test "menu holds a Log out item using the delete method" do
      html = render_user_menu(editor_menu_assigns("/"))
      doc = LazyHTML.from_fragment(html)

      logout = LazyHTML.query(doc, ~s(a[href="/users/log_out"]))
      assert Enum.count(logout) == 1
      assert LazyHTML.text(logout) =~ "Log out"
      assert LazyHTML.attribute(logout, "role") == ["menuitem"]
      assert LazyHTML.attribute(logout, "data-method") == ["delete"]
    end

    test "Profile settings activates on /users/settings" do
      html = render_user_menu(editor_menu_assigns("/users/settings"))
      doc = LazyHTML.from_fragment(html)

      active = LazyHTML.query(doc, ~s(a[aria-current="page"]))
      assert Enum.count(active) == 1
      assert LazyHTML.text(active) =~ "Profile settings"
    end

    test "Profile settings activates on nested /users/settings/confirm" do
      html = render_user_menu(editor_menu_assigns("/users/settings/confirm"))
      doc = LazyHTML.from_fragment(html)

      active = LazyHTML.query(doc, ~s(a[aria-current="page"]))
      assert Enum.count(active) == 1
      assert LazyHTML.text(active) =~ "Profile settings"
    end

    test "Profile settings does NOT activate on /users" do
      html = render_user_menu(editor_menu_assigns("/users"))
      doc = LazyHTML.from_fragment(html)

      link = account_link(doc)
      assert Enum.count(link) == 1
      assert LazyHTML.attribute(link, "aria-current") == []
      assert Enum.empty?(LazyHTML.query(doc, ~s(a[aria-current="page"])))
    end

    test "Profile settings does NOT activate on lookalike /users/settings-backup" do
      html = render_user_menu(editor_menu_assigns("/users/settings-backup"))
      doc = LazyHTML.from_fragment(html)

      link = account_link(doc)
      assert LazyHTML.attribute(link, "aria-current") == []
    end

    test "Profile settings ignores query strings on the settings family" do
      html = render_user_menu(editor_menu_assigns("/users/settings?tab=email"))
      doc = LazyHTML.from_fragment(html)

      active = LazyHTML.query(doc, ~s(a[aria-current="page"]))
      assert Enum.count(active) == 1
      assert LazyHTML.text(active) =~ "Profile settings"
    end

    test "Profile settings item has 44px minimum target" do
      html = render_user_menu(editor_menu_assigns("/"))
      doc = LazyHTML.from_fragment(html)

      classes = LazyHTML.attribute(account_link(doc), "class") |> List.first()
      assert classes =~ "min-h-11"
    end
  end

  describe "path-family matching — admin links and account-menu Settings" do
    test "Organizations activates on /admin/organizations" do
      html = render_nav(admin_assigns("/admin/organizations"))
      doc = LazyHTML.from_fragment(html)

      link = LazyHTML.query(doc, ~s(a[aria-current="page"]))
      assert LazyHTML.text(link) =~ "Organizations"
    end

    test "Organizations activates on nested /admin/organizations/123" do
      html = render_nav(admin_assigns("/admin/organizations/123"))
      doc = LazyHTML.from_fragment(html)

      link = LazyHTML.query(doc, ~s(a[aria-current="page"]))
      assert LazyHTML.text(link) =~ "Organizations"
    end

    test "the account-menu Settings item is current on the admin/users family" do
      for path <- ["/admin/users", "/admin/users/456"] do
        doc =
          menu_doc(%{
            current_path: path,
            current_organization: org(),
            user_roles: ["pathways_studio_admin"]
          })

        assert LazyHTML.attribute(LazyHTML.query(doc, "#settings-link"), "aria-current") == [
                 "page"
               ],
               "#{path} should mark the account-menu Settings item current"
      end
    end

    test "Organizations does NOT activate on /admin/users" do
      html = render_nav(admin_assigns("/admin/users"))
      doc = LazyHTML.from_fragment(html)

      org_link = LazyHTML.query(doc, ~s(a[href="/admin/organizations"]))
      assert LazyHTML.attribute(org_link, "aria-current") == []
    end

    test "the account-menu Settings item is not current on /admin/organizations" do
      doc =
        menu_doc(%{
          current_path: "/admin/organizations",
          current_organization: org(),
          user_roles: ["pathways_studio_admin"]
        })

      assert LazyHTML.attribute(LazyHTML.query(doc, "#settings-link"), "aria-current") == []
    end
  end

  describe "path-family matching — GTFS task links" do
    test "Routes activates on /gtfs/42/routes" do
      html = render_nav(editor_assigns("/gtfs/42/routes"))
      doc = LazyHTML.from_fragment(html)

      assert LazyHTML.attribute(LazyHTML.query(doc, "#nav-routes"), "aria-current") == ["page"]
    end

    test "Routes activates on nested /gtfs/42/routes/route-1" do
      html = render_nav(editor_assigns("/gtfs/42/routes/route-1"))
      doc = LazyHTML.from_fragment(html)

      assert LazyHTML.attribute(LazyHTML.query(doc, "#nav-routes"), "aria-current") == ["page"]
    end

    test "Routes covers the transfers family" do
      html = render_nav(editor_assigns("/gtfs/42/transfers"))
      doc = LazyHTML.from_fragment(html)

      assert LazyHTML.attribute(LazyHTML.query(doc, "#nav-routes"), "aria-current") == ["page"]
    end

    test "Operations covers blocks, runs and rosters" do
      for path <- ["/gtfs/42/blocks", "/gtfs/42/runs", "/gtfs/42/rosters"] do
        doc = LazyHTML.from_fragment(render_nav(editor_assigns(path)))

        assert LazyHTML.attribute(LazyHTML.query(doc, "#nav-operations"), "aria-current") == [
                 "page"
               ],
               "#{path} should select Operations"

        assert Enum.count(LazyHTML.query(doc, "#main-navigation a[aria-current='page']")) == 1
      end
    end

    test "Stops & stations activates on /gtfs/42/stops and on station pages" do
      for path <- [
            "/gtfs/42/stops",
            "/gtfs/42/stops/BROWSER_STATION/reachability",
            "/gtfs/42/stops/BROWSER_STATION/evolutions"
          ] do
        doc = LazyHTML.from_fragment(render_nav(editor_assigns(path)))

        assert LazyHTML.attribute(LazyHTML.query(doc, "#nav-stops"), "aria-current") == ["page"],
               "#{path} should select Stops & stations"
      end
    end

    test "Flex activates on /gtfs/42/flex" do
      doc = LazyHTML.from_fragment(render_nav(editor_assigns("/gtfs/42/flex")))

      assert LazyHTML.attribute(LazyHTML.query(doc, "#nav-flex"), "aria-current") == ["page"]
    end

    test "GTFS covers export, import, validation and station reachability results" do
      for path <- [
            "/gtfs/42/export",
            "/gtfs/42/import",
            "/gtfs/42/validation/run-1",
            "/gtfs/42/station-reachability/run-1"
          ] do
        doc = LazyHTML.from_fragment(render_nav(editor_assigns(path)))

        assert LazyHTML.attribute(LazyHTML.query(doc, "#nav-gtfs"), "aria-current") == ["page"],
               "#{path} should select GTFS"

        assert Enum.count(LazyHTML.query(doc, "#main-navigation a[aria-current='page']")) == 1
      end
    end

    test "GTFS destinations point at Export and keep their tabs' own pages" do
      doc = LazyHTML.from_fragment(render_nav(editor_assigns("/gtfs/42/import")))

      assert LazyHTML.attribute(LazyHTML.query(doc, "#nav-gtfs"), "href") == ["/gtfs/42/export"]
    end

    test "Routes does NOT activate on /gtfs/42/stops" do
      html = render_nav(editor_assigns("/gtfs/42/stops"))
      doc = LazyHTML.from_fragment(html)

      assert LazyHTML.attribute(LazyHTML.query(doc, "#nav-routes"), "aria-current") == []
    end

    test "Calendars and Stops & stations do not cross-select" do
      doc = LazyHTML.from_fragment(render_nav(editor_assigns("/gtfs/42/calendars")))

      assert LazyHTML.attribute(LazyHTML.query(doc, "#nav-calendars"), "aria-current") == ["page"]
      assert LazyHTML.attribute(LazyHTML.query(doc, "#nav-stops"), "aria-current") == []
    end

    test "query strings are ignored" do
      html = render_nav(editor_assigns("/gtfs/42/routes?tab=patterns"))
      doc = LazyHTML.from_fragment(html)

      assert LazyHTML.attribute(LazyHTML.query(doc, "#nav-routes"), "aria-current") == ["page"]
    end

    test "unrelated word containing family name does not activate" do
      html = render_nav(editor_assigns("/gtfs/42/imported-things"))
      doc = LazyHTML.from_fragment(html)

      assert Enum.empty?(LazyHTML.query(doc, "#main-navigation a[aria-current='page']"))
    end

    test "no link is active on the settings family or an unrelated path" do
      for path <- ["/settings", "/gtfs/42/settings", "/gtfs/42/settings/garages"] do
        html = render_nav(editor_assigns(path))
        doc = LazyHTML.from_fragment(html)

        assert Enum.empty?(LazyHTML.query(doc, "#main-navigation a[aria-current='page']"))
      end
    end
  end

  describe "account menu Settings resolution" do
    test "no organization renders no Settings item and no organization label" do
      doc =
        menu_doc(%{current_gtfs_version: gtfs_version(), user_roles: ["pathways_studio_editor"]})

      assert Enum.empty?(LazyHTML.query(doc, "#settings-link"))
      refute LazyHTML.text(LazyHTML.query(doc, "#user-menu-panel")) =~ "Test Org"
    end

    test "editor with a version links to that version's Settings" do
      doc = menu_doc(editor_menu_context("/"))
      settings = LazyHTML.query(doc, "#settings-link")

      assert Enum.count(settings) == 1
      assert LazyHTML.attribute(settings, "href") == ["/gtfs/42/settings"]
      assert LazyHTML.attribute(settings, "role") == ["menuitem"]
      assert LazyHTML.text(settings) =~ "Settings"
      assert LazyHTML.text(settings) =~ "Agencies, fares, exports, garages, fleet"
      assert LazyHTML.text(LazyHTML.query(doc, "#user-menu-panel p")) =~ "Test Org"
    end

    test "editor with a version wins over the organization-administrator fallback" do
      doc =
        menu_doc(
          Map.merge(editor_menu_context("/"), %{
            user_roles: ["pathways_studio_editor", "pathways_studio_admin"]
          })
        )

      assert LazyHTML.attribute(LazyHTML.query(doc, "#settings-link"), "href") == [
               "/gtfs/42/settings"
             ]
    end

    test "organization administrator without an editor context falls back to Users" do
      for roles <- [
            ["pathways_studio_admin"],
            ["pathways_studio_editor", "pathways_studio_admin"]
          ] do
        version = if "pathways_studio_editor" in roles, do: nil, else: gtfs_version()

        doc =
          menu_doc(%{
            current_organization: org(),
            user_roles: roles,
            current_gtfs_version: version
          })

        settings = LazyHTML.query(doc, "#settings-link")
        assert Enum.count(settings) == 1, "#{inspect(roles)} should still reach Settings"
        assert LazyHTML.attribute(settings, "href") == ["/admin/users"]
        assert LazyHTML.text(settings) =~ "Organization name, users"
      end
    end

    test "memberships with no qualifying role render no Settings item" do
      for roles <- [[], ["pathways_studio_viewer"]] do
        doc = menu_doc(%{current_organization: org(), user_roles: roles})

        assert Enum.empty?(LazyHTML.query(doc, "#settings-link"))
        refute LazyHTML.text(LazyHTML.query(doc, "#user-menu-panel")) =~ "Test Org"
      end
    end

    test "no Settings, Import or Export link sits in the main navigation" do
      doc = LazyHTML.from_fragment(render_nav(editor_assigns("/gtfs/42/export")))
      nav = LazyHTML.query(doc, "#main-navigation")

      assert Enum.empty?(LazyHTML.query(nav, "a[href*='settings']"))
      refute LazyHTML.text(nav) =~ "Settings"
      assert Enum.empty?(LazyHTML.query(nav, "a[href$='/import']"))
    end
  end

  describe "product filtering (ProductSurfaces)" do
    defp planner_struct_org,
      do: %Organization{id: 1, alias: "test-org", name: "Test Org", product: :planner}

    defp pathways_struct_org,
      do: %Organization{id: 1, alias: "test-org", name: "Test Org", product: :pathways}

    defp product_editor_assigns(org) do
      %{
        current_user: editor_user(),
        current_organization: org,
        user_roles: ["pathways_studio_editor"],
        current_path: "/gtfs/42/routes",
        current_gtfs_version: gtfs_version()
      }
    end

    test "planner organization renders all six task links" do
      doc = LazyHTML.from_fragment(render_nav(product_editor_assigns(planner_struct_org())))

      for id <- [
            "nav-routes",
            "nav-calendars",
            "nav-operations",
            "nav-stops",
            "nav-flex",
            "nav-gtfs"
          ] do
        refute Enum.empty?(LazyHTML.query(doc, "##{id}")),
               "expected ##{id} for a planner organization"
      end
    end

    test "pathways organization hides Operations and Flex and keeps the other four" do
      doc = LazyHTML.from_fragment(render_nav(product_editor_assigns(pathways_struct_org())))

      for id <- ["nav-routes", "nav-calendars", "nav-stops", "nav-gtfs"] do
        refute Enum.empty?(LazyHTML.query(doc, "##{id}")),
               "expected ##{id} for a pathways organization"
      end

      assert Enum.empty?(LazyHTML.query(doc, "#nav-operations"))
      assert Enum.empty?(LazyHTML.query(doc, "#nav-flex"))
    end

    test "nil organization does not crash the product filter" do
      html = render_nav(product_editor_assigns(nil))
      doc = LazyHTML.from_fragment(html)

      # The pre-existing show_tasks gate (unchanged by this step) renders no
      # task links without an organization; nil staying visible is proven by
      # ProductSurfaces.visible?(nil, _) in EV-2.
      assert Enum.empty?(LazyHTML.query(doc, "#main-navigation a"))
      assert nav_link_texts(html) == []
    end

    test "planner editor keeps the version Settings entry" do
      doc =
        menu_doc(%{
          current_organization: planner_struct_org(),
          user_roles: ["pathways_studio_editor"],
          current_gtfs_version: gtfs_version()
        })

      settings = LazyHTML.query(doc, "#settings-link")
      assert Enum.count(settings) == 1
      assert LazyHTML.attribute(settings, "href") == ["/gtfs/42/settings"]
      assert LazyHTML.text(settings) =~ "Agencies, fares, exports, garages, fleet"
    end

    test "pathways editor without admin renders no Settings entry" do
      doc =
        menu_doc(%{
          current_organization: pathways_struct_org(),
          user_roles: ["pathways_studio_editor"],
          current_gtfs_version: gtfs_version()
        })

      assert Enum.empty?(LazyHTML.query(doc, "#settings-link"))
      refute LazyHTML.text(LazyHTML.query(doc, "#user-menu-panel")) =~ "Test Org"
    end

    test "pathways editor with admin falls back to the Users Settings entry" do
      doc =
        menu_doc(%{
          current_organization: pathways_struct_org(),
          user_roles: ["pathways_studio_editor", "pathways_studio_admin"],
          current_gtfs_version: gtfs_version()
        })

      settings = LazyHTML.query(doc, "#settings-link")
      assert Enum.count(settings) == 1
      assert LazyHTML.attribute(settings, "href") == ["/admin/users"]
      assert LazyHTML.text(settings) =~ "Organization name, users"
    end
  end

  describe "Settings and menu current state" do
    test "the Settings item is current across the version Settings family" do
      for path <- ["/gtfs/42/settings", "/gtfs/42/settings/garages", "/gtfs/42/settings?tab=x"] do
        doc = menu_doc(editor_menu_context(path))

        assert LazyHTML.attribute(LazyHTML.query(doc, "#settings-link"), "aria-current") == [
                 "page"
               ],
               "#{path} should mark Settings current"
      end
    end

    test "an organization administrator's Settings item is current on /admin/users" do
      doc =
        menu_doc(%{
          current_path: "/admin/users/456",
          current_organization: org(),
          user_roles: ["pathways_studio_admin"]
        })

      assert LazyHTML.attribute(LazyHTML.query(doc, "#settings-link"), "aria-current") == ["page"]
    end

    test "the Settings item is not current on lookalike or unrelated paths" do
      for path <- [
            "/gtfs/42/settings-backup",
            "/gtfs/42/routes",
            "/admin/organizations",
            "/users/settings"
          ] do
        doc = menu_doc(editor_menu_context(path))

        assert LazyHTML.attribute(LazyHTML.query(doc, "#settings-link"), "aria-current") == [],
               "#{path} should not mark Settings current"
      end
    end

    test "the trigger carries data-current and the selection tint on its three families" do
      for path <- [
            "/gtfs/42/settings",
            "/gtfs/42/settings/fleet",
            "/admin/users",
            "/users/settings"
          ] do
        doc = menu_doc(editor_menu_context(path))
        trigger = LazyHTML.query(doc, "[data-user-menu-trigger]")

        assert LazyHTML.attribute(trigger, "data-current") == ["true"],
               "#{path} should mark the trigger current"

        assert LazyHTML.attribute(trigger, "class") |> List.first() =~ "bg-selection"
      end
    end

    test "the trigger is not current elsewhere" do
      for path <- ["/gtfs/42/routes", "/admin/organizations", "/settings", "/"] do
        doc = menu_doc(editor_menu_context(path))
        trigger = LazyHTML.query(doc, "[data-user-menu-trigger]")

        assert LazyHTML.attribute(trigger, "data-current") == [],
               "#{path} is not a current family"

        refute LazyHTML.attribute(trigger, "class") |> List.first() =~ "bg-selection"
      end
    end
  end

  describe "account initials" do
    defp trigger_initials(email) do
      html = render_user_menu(%{current_user: %{id: 2, email: email}, current_path: "/"})
      doc = LazyHTML.from_fragment(html)

      LazyHTML.query(doc, "[data-user-menu-trigger] span") |> LazyHTML.text() |> String.trim()
    end

    test "takes the first letter of up to two local-part segments" do
      assert trigger_initials("dana@northcoast.example") == "D"
      assert trigger_initials("alex.kim@northcoast.example") == "AK"
      assert trigger_initials("j_o-smith@northcoast.example") == "JO"
      assert trigger_initials("ana+ops@northcoast.example") == "AO"
      assert trigger_initials("a_b_c@northcoast.example") == "AB"
    end

    test "falls back to the email's first grapheme when the local part is empty" do
      assert trigger_initials("@northcoast.example") == "@"
    end

    test "is display text only, never a second accessible name" do
      doc = LazyHTML.from_fragment(render_user_menu(editor_menu_assigns("/")))
      trigger = LazyHTML.query(doc, "[data-user-menu-trigger]")

      assert LazyHTML.attribute(trigger, "aria-label") == ["Account menu for editor@test.com"]
    end
  end

  describe "active state presentation" do
    test "active link has aria-current=page and non-color cue" do
      html = render_nav(admin_assigns("/admin/organizations"))
      doc = LazyHTML.from_fragment(html)

      link = LazyHTML.query(doc, ~s(a[aria-current="page"]))
      classes = LazyHTML.attribute(link, "class") |> List.first()

      # Non-color cue: the bolder label carries the state; the tint follows
      # aria-current, so selection is never signalled by hue alone.
      assert classes =~ "font-semibold"
      assert classes =~ "aria-[current=page]:bg-selection"
      assert classes =~ "aria-[current=page]:text-action"
    end

    test "inactive links do not carry aria-current" do
      html = render_nav(admin_assigns("/admin/organizations"))
      doc = LazyHTML.from_fragment(html)

      inactive = LazyHTML.query(doc, "a:not([aria-current])")
      refute Enum.empty?(inactive)
    end
  end

  describe "target sizing and wrapping" do
    test "nav links have 44px minimum target" do
      html = render_nav(admin_assigns("/admin/organizations"))
      doc = LazyHTML.from_fragment(html)

      links = LazyHTML.query(doc, "nav a")
      classes = LazyHTML.attribute(links, "class") |> List.first()

      assert classes =~ "min-h-11"
    end

    test "nav container wraps" do
      html = render_nav(admin_assigns("/admin/organizations"))
      doc = LazyHTML.from_fragment(html)

      nav = LazyHTML.query(doc, "nav")
      classes = LazyHTML.attribute(nav, "class") |> List.first()

      assert classes =~ "flex-wrap"
    end
  end

  describe "role gating" do
    test "administrator sees Organizations link" do
      html = render_nav(admin_assigns("/"))
      assert html =~ "Organizations"
    end

    test "non-administrator does not see Organizations link" do
      html = render_nav(editor_assigns("/"))
      refute html =~ "Organizations"
    end

    test "editor sees the six label-only task links and their destinations" do
      html = render_nav(editor_assigns("/"))
      doc = LazyHTML.from_fragment(html)

      assert nav_link_texts(html) == [
               "Routes",
               "Calendars",
               "Operations",
               "Stops & stations",
               "Flex",
               "GTFS"
             ]

      assert LazyHTML.attribute(LazyHTML.query(doc, "#main-navigation a"), "href") == [
               "/gtfs/42/routes",
               "/gtfs/42/calendars",
               "/gtfs/42/blocks",
               "/gtfs/42/stops",
               "/gtfs/42/flex",
               "/gtfs/42/export"
             ]
    end

    test "user without editor role does not see GTFS links" do
      assigns = %{
        current_user: editor_user(),
        current_organization: org(),
        user_roles: [],
        current_path: "/",
        current_gtfs_version: gtfs_version()
      }

      html = render_nav(assigns)
      refute html =~ "Routes"
      refute html =~ "Stops"
    end
  end

  describe "station_sub_nav" do
    defp render_station_sub_nav(assigns) do
      assigns =
        Map.merge(
          %{
            station: %{stop_id: "stop-1", stop_name: "Central Station"},
            gtfs_version_id: 42,
            active_tab: :details,
            actions: []
          },
          assigns
        )

      rendered_to_string(~H"""
      <.station_sub_nav
        station={@station}
        gtfs_version_id={@gtfs_version_id}
        active_tab={@active_tab}
      >
        <:actions :if={@actions != []}>
          <button :for={a <- @actions}>{a}</button>
        </:actions>
      </.station_sub_nav>
      """)
    end

    test "renders ordinary navigation links without tablist or tab roles" do
      html = render_station_sub_nav(%{})
      refute html =~ ~s(role="tablist")
      refute html =~ ~s(role="tab")
      refute html =~ "aria-selected"
    end

    test "active tab has aria-current=page" do
      html = render_station_sub_nav(%{active_tab: :details})
      doc = LazyHTML.from_fragment(html)

      link = LazyHTML.query(doc, ~s(#station-sub-nav a[aria-current="page"]))
      assert LazyHTML.text(link) =~ "Details"
    end

    test "inactive tabs do not have aria-current" do
      html = render_station_sub_nav(%{active_tab: :details})
      doc = LazyHTML.from_fragment(html)

      diagram_link =
        LazyHTML.query(doc, ~s(#station-sub-nav a[href="/gtfs/42/stops/stop-1/diagram"]))

      assert LazyHTML.attribute(diagram_link, "aria-current") == []
    end

    test "back link has 44px target and accessible name" do
      html = render_station_sub_nav(%{})
      doc = LazyHTML.from_fragment(html)

      back = LazyHTML.query(doc, ~s(#station-sub-nav a[aria-label="Back to stations list"]))
      assert Enum.count(back) == 1
      classes = LazyHTML.attribute(back, "class") |> List.first()
      assert classes =~ "min-h-11"
    end

    test "long station name wraps" do
      html =
        render_station_sub_nav(%{
          station: %{
            stop_id: "stop-1",
            stop_name:
              "A Very Long Station Name That Should Wrap At Narrow Widths Without Breaking"
          }
        })

      doc = LazyHTML.from_fragment(html)
      heading = LazyHTML.query(doc, "#station-sub-nav h1")
      classes = LazyHTML.attribute(heading, "class") |> List.first()
      assert classes =~ "break-words"
    end

    test "actions slot renders in the identity row" do
      html = render_station_sub_nav(%{active_tab: :diagram, actions: ["Apply naming"]})
      assert html =~ "Apply naming"
    end

    test "does not render level, upload, or mode controls" do
      html = render_station_sub_nav(%{active_tab: :diagram})
      refute html =~ "Add level"
      refute html =~ "upload"
      refute html =~ "switch_level"
    end

    test "renders exactly five navigation links" do
      html = render_station_sub_nav(%{})
      doc = LazyHTML.from_fragment(html)
      links = LazyHTML.query(doc, "#station-sub-nav nav a")
      assert Enum.count(links) == 5
    end

    test "appends Evolutions after Reachability and keeps the station identity" do
      html = render_station_sub_nav(%{active_tab: :reachability})
      doc = LazyHTML.from_fragment(html)
      links = LazyHTML.query(doc, "#station-sub-nav nav a")

      assert sub_nav_texts(links) == [
               "Details",
               "Floorplans",
               "Reports",
               "Reachability",
               "Evolutions"
             ]

      assert sub_nav_attr(links, "href") |> List.last() ==
               "/gtfs/42/stops/stop-1/evolutions"

      current = current_sub_nav_links(links)
      assert sub_nav_texts(current) == ["Reachability"]

      assert Enum.count(
               LazyHTML.query(doc, ~s(#station-sub-nav a[aria-label="Back to stations list"]))
             ) == 1

      assert String.trim(LazyHTML.text(LazyHTML.query(doc, "#station-sub-nav h1"))) ==
               "Central Station"
    end

    test "Evolutions tab carries the stable link ID and becomes current" do
      html = render_station_sub_nav(%{active_tab: :evolutions})
      doc = LazyHTML.from_fragment(html)
      links = LazyHTML.query(doc, "#station-sub-nav nav a")

      assert LazyHTML.attribute(LazyHTML.query(doc, "#station-tab-evolutions"), "href") == [
               "/gtfs/42/stops/stop-1/evolutions"
             ]

      assert sub_nav_texts(current_sub_nav_links(links)) == ["Evolutions"]
    end

    test "Floorplans link points to diagram route" do
      html = render_station_sub_nav(%{})
      doc = LazyHTML.from_fragment(html)
      link = LazyHTML.query(doc, ~s(#station-sub-nav a[href$="/diagram"]))
      assert Enum.count(link) == 1
      assert LazyHTML.text(link) =~ "Floorplans"
    end
  end

  describe "route_sub_nav" do
    defp render_route_sub_nav(assigns) do
      assigns =
        Map.merge(
          %{
            route: %{
              route_id: "route-1",
              route_short_name: "42",
              route_long_name: "Crosstown"
            },
            gtfs_version_id: 42,
            active_tab: :details
          },
          assigns
        )

      rendered_to_string(~H"""
      <.route_sub_nav
        route={@route}
        gtfs_version_id={@gtfs_version_id}
        active_tab={@active_tab}
      />
      """)
    end

    test "renders ordinary navigation links without tablist or tab roles" do
      html = render_route_sub_nav(%{})
      refute html =~ ~s(role="tablist")
      refute html =~ ~s(role="tab")
      refute html =~ "aria-selected"
    end

    test "active tab has aria-current=page" do
      html = render_route_sub_nav(%{active_tab: :patterns})
      doc = LazyHTML.from_fragment(html)

      link = LazyHTML.query(doc, ~s(nav a[aria-current="page"]))
      assert LazyHTML.text(link) =~ "Patterns"
    end

    test "back link has 44px target and accessible name" do
      html = render_route_sub_nav(%{})
      doc = LazyHTML.from_fragment(html)

      back = LazyHTML.query(doc, ~s(nav a[aria-label="Back to routes list"]))
      assert Enum.count(back) == 1
      classes = LazyHTML.attribute(back, "class") |> List.first()
      assert classes =~ "min-h-11"
    end
  end

  describe "routes_tabs" do
    defp render_routes_tabs(active_tab) do
      assigns = %{active_tab: active_tab}

      rendered_to_string(~H"""
      <.routes_tabs gtfs_version_id={42} active_tab={@active_tab} />
      """)
    end

    test "declares Routes then Transfers with exact destinations and stable link IDs" do
      html = render_routes_tabs(:routes)
      links = sub_nav_links(html, "routes-tabs")

      assert sub_nav_texts(links) == ["Routes", "Transfers"]
      assert sub_nav_attr(links, "href") == ["/gtfs/42/routes", "/gtfs/42/transfers"]

      assert sub_nav_attr(links, "id") == [
               "routes-tab-routes",
               "routes-tab-transfers"
             ]

      assert_sub_nav_contract(html, "routes-tabs")
    end

    for {active_tab, label} <- [{:routes, "Routes"}, {:transfers, "Transfers"}] do
      test "#{active_tab} marks exactly one current link" do
        links = sub_nav_links(render_routes_tabs(unquote(active_tab)), "routes-tabs")

        assert sub_nav_attr(links, "aria-current") == ["page"]
        assert sub_nav_texts(current_sub_nav_links(links)) == [unquote(label)]
      end
    end
  end

  describe "operations_sub_nav" do
    defp render_operations_sub_nav(active_tab) do
      assigns = %{active_tab: active_tab}

      rendered_to_string(~H"""
      <.operations_sub_nav gtfs_version_id={42} active_tab={@active_tab} />
      """)
    end

    test "declares Blocks, Runs, Rosters with exact destinations and stable link IDs" do
      html = render_operations_sub_nav(:blocks)
      links = sub_nav_links(html, "operations-sub-nav")

      assert sub_nav_texts(links) == ["Blocks", "Runs", "Rosters"]

      assert sub_nav_attr(links, "href") == [
               "/gtfs/42/blocks",
               "/gtfs/42/runs",
               "/gtfs/42/rosters"
             ]

      assert sub_nav_attr(links, "id") == [
               "operations-tab-blocks",
               "operations-tab-runs",
               "operations-tab-rosters"
             ]

      assert_sub_nav_contract(html, "operations-sub-nav")
    end

    for {active_tab, label} <- [
          {:blocks, "Blocks"},
          {:runs, "Runs"},
          {:rosters, "Rosters"}
        ] do
      test "#{active_tab} marks exactly one current link" do
        links =
          sub_nav_links(render_operations_sub_nav(unquote(active_tab)), "operations-sub-nav")

        assert sub_nav_attr(links, "aria-current") == ["page"]
        assert sub_nav_texts(current_sub_nav_links(links)) == [unquote(label)]
      end
    end
  end

  describe "gtfs_sub_nav" do
    defp render_gtfs_sub_nav(active_tab) do
      assigns = %{active_tab: active_tab}

      rendered_to_string(~H"""
      <.gtfs_sub_nav gtfs_version_id={42} active_tab={@active_tab} />
      """)
    end

    test "declares Export then Import with exact destinations and stable link IDs" do
      html = render_gtfs_sub_nav(:export)
      links = sub_nav_links(html, "gtfs-sub-nav")

      assert sub_nav_texts(links) == ["Export", "Import"]
      assert sub_nav_attr(links, "href") == ["/gtfs/42/export", "/gtfs/42/import"]
      assert sub_nav_attr(links, "id") == ["gtfs-tab-export", "gtfs-tab-import"]

      assert_sub_nav_contract(html, "gtfs-sub-nav")
    end

    for {active_tab, label} <- [{:export, "Export"}, {:import, "Import"}] do
      test "#{active_tab} marks exactly one current link" do
        links = sub_nav_links(render_gtfs_sub_nav(unquote(active_tab)), "gtfs-sub-nav")

        assert sub_nav_attr(links, "aria-current") == ["page"]
        assert sub_nav_texts(current_sub_nav_links(links)) == [unquote(label)]
      end
    end
  end

  describe "header" do
    test "renders h1 with correct hierarchy class" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.header>
          Page Title
          <:subtitle>Some subtitle</:subtitle>
        </.header>
        """)

      doc = LazyHTML.from_fragment(html)
      h1 = LazyHTML.query(doc, "header h1")
      assert LazyHTML.text(h1) =~ "Page Title"
    end

    test "actions stack at narrow widths" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.header>
          Title
          <:actions>
            <button>Action</button>
          </:actions>
        </.header>
        """)

      doc = LazyHTML.from_fragment(html)
      header = LazyHTML.query(doc, "header")
      classes = LazyHTML.attribute(header, "class") |> List.first()
      assert classes =~ "flex-col"
      assert classes =~ "sm:flex-row"
    end
  end

  describe "pressed_filter/1 experimental contract" do
    test "renders button with aria-pressed state" do
      assigns = %{pressed: true}

      html =
        rendered_to_string(~H"""
        <.pressed_filter
          id="filter-active"
          pressed={@pressed}
          event="toggle_filter"
          value="active"
        >
          <span>Active</span>
        </.pressed_filter>
        """)

      doc = LazyHTML.from_fragment(html)
      button = LazyHTML.query(doc, "#filter-active")
      assert LazyHTML.attribute(button, "aria-pressed") == ["true"]
      assert LazyHTML.text(button) =~ "Active"
    end

    test "unpressed button has aria-pressed=false" do
      assigns = %{pressed: false}

      html =
        rendered_to_string(~H"""
        <.pressed_filter
          id="filter-active"
          pressed={@pressed}
          event="toggle_filter"
          value="active"
        >
          Active
        </.pressed_filter>
        """)

      doc = LazyHTML.from_fragment(html)
      button = LazyHTML.query(doc, "#filter-active")
      assert LazyHTML.attribute(button, "aria-pressed") == ["false"]
    end

    test "button has 44px target" do
      assigns = %{pressed: false}

      html =
        rendered_to_string(~H"""
        <.pressed_filter
          id="filter-active"
          pressed={@pressed}
          event="toggle_filter"
          value="active"
        >
          Active
        </.pressed_filter>
        """)

      doc = LazyHTML.from_fragment(html)
      button = LazyHTML.query(doc, "#filter-active")
      classes = LazyHTML.attribute(button, "class") |> List.first()
      assert classes =~ "h-11"
      assert classes =~ "min-w-[44px]"
    end

    test "button sends configured event and value" do
      assigns = %{pressed: false}

      html =
        rendered_to_string(~H"""
        <.pressed_filter
          id="filter-active"
          pressed={@pressed}
          event="toggle_filter"
          value="active"
        >
          Active
        </.pressed_filter>
        """)

      doc = LazyHTML.from_fragment(html)
      button = LazyHTML.query(doc, "#filter-active")
      assert LazyHTML.attribute(button, "phx-click") == ["toggle_filter"]
      assert LazyHTML.attribute(button, "phx-value") == ["active"]
    end

    test "pending button shows pending label" do
      assigns = %{pressed: false}

      html =
        rendered_to_string(~H"""
        <.pressed_filter
          id="filter-active"
          pressed={@pressed}
          event="toggle_filter"
          value="active"
          pending={true}
          pending_label="Loading…"
        >
          Active
        </.pressed_filter>
        """)

      assert html =~ "Loading…"
      doc = LazyHTML.from_fragment(html)
      button = LazyHTML.query(doc, "#filter-active")
      assert LazyHTML.attribute(button, "disabled") == [""]
    end

    test "disabled button shows disabled reason" do
      assigns = %{pressed: false}

      html =
        rendered_to_string(~H"""
        <.pressed_filter
          id="filter-active"
          pressed={@pressed}
          event="toggle_filter"
          value="active"
          disabled={true}
          disabled_reason="Not available"
        >
          Active
        </.pressed_filter>
        """)

      doc = LazyHTML.from_fragment(html)
      button = LazyHTML.query(doc, "#filter-active")
      assert LazyHTML.attribute(button, "disabled") == [""]
      assert LazyHTML.attribute(button, "title") == ["Not available"]
    end
  end

  describe "app layout version switcher guard" do
    test "does not render the switcher without a current organization" do
      assigns = %{
        current_user: editor_user(),
        current_gtfs_version: gtfs_version(),
        available_versions: [{42, "v1"}]
      }

      html =
        rendered_to_string(~H"""
        <Layouts.app
          flash={%{}}
          current_user={@current_user}
          current_gtfs_version={@current_gtfs_version}
          available_versions={@available_versions}
        >
          <p>Page content</p>
        </Layouts.app>
        """)

      assert html =~ "Page content"
      refute html =~ "id=\"gtfs-version-switcher\""
    end
  end

  describe "segmented_control/1 experimental contract" do
    test "an option's icon renders before its label and keeps the radio input" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.segmented_control
          id="mode"
          name="mode"
          legend="Mode"
          options={[%{label: "Select", value: "view", icon: "hero-map-pin"}, {"Align", "map"}]}
          value="view"
          event="switch_mode"
        />
        """)

      doc = LazyHTML.from_fragment(html)

      assert Enum.count(
               LazyHTML.query(doc, "label[for='mode-option-view'] [class*='hero-map-pin']")
             ) ==
               1

      assert Enum.empty?(LazyHTML.query(doc, "label[for='mode-option-map'] [class*='hero-']"))
      assert Enum.count(LazyHTML.query(doc, "#mode input[type='radio']")) == 2
    end

    test "renders fieldset with legend and radio inputs" do
      assigns = %{value: "list"}

      html =
        rendered_to_string(~H"""
        <.segmented_control
          id="view-mode"
          name="view_mode"
          legend="View mode"
          options={[{"List", "list"}, {"Map", "map"}]}
          value={@value}
          event="change_view"
        />
        """)

      doc = LazyHTML.from_fragment(html)
      fieldset = LazyHTML.query(doc, "#view-mode")
      assert Enum.count(fieldset) == 1

      legend = LazyHTML.query(doc, "#view-mode legend")
      assert LazyHTML.text(legend) =~ "View mode"

      radios = LazyHTML.query(doc, "#view-mode input[type='radio']")
      assert Enum.count(radios) == 2
    end

    test "selected option has checked attribute" do
      assigns = %{value: "map"}

      html =
        rendered_to_string(~H"""
        <.segmented_control
          id="view-mode"
          name="view_mode"
          legend="View mode"
          options={[{"List", "list"}, {"Map", "map"}]}
          value={@value}
          event="change_view"
        />
        """)

      doc = LazyHTML.from_fragment(html)
      map_radio = LazyHTML.query(doc, ~s(#view-mode input[value="map"]))
      assert LazyHTML.attribute(map_radio, "checked") == [""]

      list_radio = LazyHTML.query(doc, ~s(#view-mode input[value="list"]))
      assert LazyHTML.attribute(list_radio, "checked") == []
    end

    test "form sends configured change event and radios carry their value" do
      assigns = %{value: "list"}

      html =
        rendered_to_string(~H"""
        <.segmented_control
          id="view-mode"
          name="view_mode"
          legend="View mode"
          options={[{"List", "list"}, {"Map", "map"}]}
          value={@value}
          event="change_view"
        />
        """)

      doc = LazyHTML.from_fragment(html)

      # phx-change on a wrapping form fires for both mouse and keyboard selection
      # (arrow keys emit change, not click), so the server always receives the event.
      form = LazyHTML.query(doc, "form")
      assert LazyHTML.attribute(form, "phx-change") == ["change_view"]

      list_radio = LazyHTML.query(doc, ~s(#view-mode input[value="list"]))
      assert LazyHTML.attribute(list_radio, "name") == ["view_mode"]
    end

    test "disabled fieldset shows disabled reason" do
      assigns = %{value: "list"}

      html =
        rendered_to_string(~H"""
        <.segmented_control
          id="view-mode"
          name="view_mode"
          legend="View mode"
          options={[{"List", "list"}]}
          value={@value}
          event="change_view"
          disabled={true}
          disabled_reason="Not available"
        />
        """)

      doc = LazyHTML.from_fragment(html)
      fieldset = LazyHTML.query(doc, "#view-mode")
      assert LazyHTML.attribute(fieldset, "disabled") == [""]

      assert html =~ "Not available"
    end

    test "options wrap at narrow widths" do
      assigns = %{value: "list"}

      html =
        rendered_to_string(~H"""
        <.segmented_control
          id="view-mode"
          name="view_mode"
          legend="View mode"
          options={[{"List", "list"}, {"Map", "map"}, {"Table", "table"}]}
          value={@value}
          event="change_view"
        />
        """)

      doc = LazyHTML.from_fragment(html)
      container = LazyHTML.query(doc, "#view-mode div.flex")
      classes = LazyHTML.attribute(container, "class") |> List.first()
      assert classes =~ "flex-wrap"
    end

    test "normalizes tuple and map options while keeping disabled reasons adjacent" do
      assigns = %{value: "list"}

      html =
        rendered_to_string(~H"""
        <.segmented_control
          id="workspace-mode"
          name="workspace_mode"
          legend="Workspace mode"
          options={[
            {"List", "list"},
            %{label: "Map", value: "map", disabled: true, disabled_reason: "Upload a diagram first"}
          ]}
          value={@value}
          event="change_view"
        />
        """)

      doc = LazyHTML.from_fragment(html)
      radios = LazyHTML.query(doc, "#workspace-mode input[type='radio']")
      assert Enum.count(radios) == 2
      assert Enum.all?(radios, &(LazyHTML.attribute(&1, "name") == ["workspace_mode"]))

      map_radio = LazyHTML.query(doc, ~s(#workspace-mode input[value="map"]))
      assert LazyHTML.attribute(map_radio, "disabled") == [""]

      assert LazyHTML.attribute(map_radio, "aria-describedby") == [
               "workspace-mode-option-map-reason"
             ]

      refute Enum.empty?(LazyHTML.query(doc, "#workspace-mode-option-map-reason"))

      assert LazyHTML.text(LazyHTML.query(doc, "#workspace-mode-option-map-reason")) =~
               "Upload a diagram first"
    end

    test "uses native radio behavior without focus-push markup" do
      assigns = %{value: "list"}

      html =
        rendered_to_string(~H"""
        <.segmented_control
          id="workspace-mode"
          name="workspace_mode"
          legend="Workspace mode"
          options={[{"List", "list"}, {"Map", "map"}]}
          value={@value}
          event="change_view"
        />
        """)

      doc = LazyHTML.from_fragment(html)
      assert Enum.empty?(LazyHTML.query(doc, "#workspace-mode [phx-focus]"))
      assert Enum.empty?(LazyHTML.query(doc, "#workspace-mode [data-focus-target]"))
      assert Enum.empty?(LazyHTML.query(doc, "#workspace-mode [phx-hook]"))
    end
  end
end
