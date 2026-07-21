defmodule GtfsPlannerWeb.NavigationComponentsTest do
  use GtfsPlannerWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Phoenix.Component
  import GtfsPlannerWeb.CoreComponents

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
    rendered_to_string(~H"""
    <Navigation.user_menu current_user={@current_user} current_path={@current_path} />
    """)
  end

  defp editor_menu_assigns(path) do
    %{current_user: editor_user(), current_path: path}
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

  describe "top_nav excludes account actions" do
    test "task navigation omits the Account settings link" do
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

    test "organization admin sees Users, not GTFS tasks or an account link" do
      html = render_nav(org_admin_assigns("/"))
      doc = LazyHTML.from_fragment(html)

      assert Enum.empty?(account_link(doc))
      assert html =~ "Users"
      refute html =~ "Routes"
      refute html =~ "Organizations"
    end

    test "no-task role sees an empty task nav" do
      html = render_nav(no_task_assigns("/"))

      assert nav_link_texts(html) == []
    end

    test "declared visual order lists only task links" do
      texts = nav_link_texts(render_nav(admin_assigns("/")))

      assert texts == [
               "Organizations",
               "Users",
               "Routes",
               "Stops & stations",
               "Import",
               "Export"
             ]
    end
  end

  describe "user_menu account actions" do
    test "icon-only trigger opens a menu, labeled with the signed-in email" do
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

    test "menu holds exactly one Account settings item" do
      html = render_user_menu(editor_menu_assigns("/"))
      doc = LazyHTML.from_fragment(html)

      links = account_link(doc)
      assert Enum.count(links) == 1
      assert LazyHTML.text(links) =~ "Account settings"
      assert LazyHTML.attribute(links, "role") == ["menuitem"]
      assert html =~ "hero-cog-6-tooth"
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

    test "Account settings activates on /users/settings" do
      html = render_user_menu(editor_menu_assigns("/users/settings"))
      doc = LazyHTML.from_fragment(html)

      active = LazyHTML.query(doc, ~s(a[aria-current="page"]))
      assert Enum.count(active) == 1
      assert LazyHTML.text(active) =~ "Account settings"
    end

    test "Account settings activates on nested /users/settings/confirm" do
      html = render_user_menu(editor_menu_assigns("/users/settings/confirm"))
      doc = LazyHTML.from_fragment(html)

      active = LazyHTML.query(doc, ~s(a[aria-current="page"]))
      assert Enum.count(active) == 1
      assert LazyHTML.text(active) =~ "Account settings"
    end

    test "Account settings does NOT activate on /users" do
      html = render_user_menu(editor_menu_assigns("/users"))
      doc = LazyHTML.from_fragment(html)

      link = account_link(doc)
      assert Enum.count(link) == 1
      assert LazyHTML.attribute(link, "aria-current") == []
      assert Enum.empty?(LazyHTML.query(doc, ~s(a[aria-current="page"])))
    end

    test "Account settings does NOT activate on lookalike /users/settings-backup" do
      html = render_user_menu(editor_menu_assigns("/users/settings-backup"))
      doc = LazyHTML.from_fragment(html)

      link = account_link(doc)
      assert LazyHTML.attribute(link, "aria-current") == []
    end

    test "Account settings ignores query strings on the settings family" do
      html = render_user_menu(editor_menu_assigns("/users/settings?tab=email"))
      doc = LazyHTML.from_fragment(html)

      active = LazyHTML.query(doc, ~s(a[aria-current="page"]))
      assert Enum.count(active) == 1
      assert LazyHTML.text(active) =~ "Account settings"
    end

    test "Account settings item has 44px minimum target" do
      html = render_user_menu(editor_menu_assigns("/"))
      doc = LazyHTML.from_fragment(html)

      classes = LazyHTML.attribute(account_link(doc), "class") |> List.first()
      assert classes =~ "min-h-11"
    end
  end

  describe "path-family matching — admin links" do
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

    test "Users activates on /admin/users" do
      html = render_nav(admin_assigns("/admin/users"))
      doc = LazyHTML.from_fragment(html)

      link = LazyHTML.query(doc, ~s(a[aria-current="page"]))
      assert LazyHTML.text(link) =~ "Users"
    end

    test "Users activates on nested /admin/users/456" do
      html = render_nav(admin_assigns("/admin/users/456"))
      doc = LazyHTML.from_fragment(html)

      link = LazyHTML.query(doc, ~s(a[aria-current="page"]))
      assert LazyHTML.text(link) =~ "Users"
    end

    test "Organizations does NOT activate on /admin/users" do
      html = render_nav(admin_assigns("/admin/users"))
      doc = LazyHTML.from_fragment(html)

      org_link = LazyHTML.query(doc, ~s(a[href="/admin/organizations"]))
      assert LazyHTML.attribute(org_link, "aria-current") == []
    end

    test "Users does NOT activate on /admin/organizations" do
      html = render_nav(admin_assigns("/admin/organizations"))
      doc = LazyHTML.from_fragment(html)

      users_link = LazyHTML.query(doc, ~s(a[href="/admin/users"]))
      assert LazyHTML.attribute(users_link, "aria-current") == []
    end
  end

  describe "path-family matching — GTFS task links" do
    test "Routes activates on /gtfs/42/routes" do
      html = render_nav(editor_assigns("/gtfs/42/routes"))
      doc = LazyHTML.from_fragment(html)

      link = LazyHTML.query(doc, ~s(a[aria-current="page"]))
      assert LazyHTML.text(link) =~ "Routes"
    end

    test "Routes activates on nested /gtfs/42/routes/route-1" do
      html = render_nav(editor_assigns("/gtfs/42/routes/route-1"))
      doc = LazyHTML.from_fragment(html)

      link = LazyHTML.query(doc, ~s(a[aria-current="page"]))
      assert LazyHTML.text(link) =~ "Routes"
    end

    test "Stops & stations activates on /gtfs/42/stops" do
      html = render_nav(editor_assigns("/gtfs/42/stops"))
      doc = LazyHTML.from_fragment(html)

      link = LazyHTML.query(doc, ~s(a[aria-current="page"]))
      assert LazyHTML.text(link) =~ "Stops & stations"
    end

    test "Import activates on /gtfs/42/import" do
      html = render_nav(editor_assigns("/gtfs/42/import"))
      doc = LazyHTML.from_fragment(html)

      link = LazyHTML.query(doc, ~s(a[aria-current="page"]))
      assert LazyHTML.text(link) =~ "Import"
    end

    test "Export activates on /gtfs/42/export" do
      html = render_nav(editor_assigns("/gtfs/42/export"))
      doc = LazyHTML.from_fragment(html)

      link = LazyHTML.query(doc, ~s(a[aria-current="page"]))
      assert LazyHTML.text(link) =~ "Export"
    end

    test "Routes does NOT activate on /gtfs/42/stops" do
      html = render_nav(editor_assigns("/gtfs/42/stops"))
      doc = LazyHTML.from_fragment(html)

      routes_link = LazyHTML.query(doc, ~s(a[href="/gtfs/42/routes"]))
      assert LazyHTML.attribute(routes_link, "aria-current") == []
    end

    test "query strings are ignored" do
      html = render_nav(editor_assigns("/gtfs/42/routes?tab=patterns"))
      doc = LazyHTML.from_fragment(html)

      link = LazyHTML.query(doc, ~s(a[aria-current="page"]))
      assert LazyHTML.text(link) =~ "Routes"
    end

    test "unrelated word containing family name does not activate" do
      html = render_nav(editor_assigns("/gtfs/42/imported-things"))
      doc = LazyHTML.from_fragment(html)

      import_link = LazyHTML.query(doc, ~s(a[href="/gtfs/42/import"]))
      assert LazyHTML.attribute(import_link, "aria-current") == []
    end

    test "no link is active on unrelated path" do
      html = render_nav(editor_assigns("/settings"))
      doc = LazyHTML.from_fragment(html)

      assert Enum.empty?(LazyHTML.query(doc, ~s(a[aria-current="page"])))
    end
  end

  describe "active state presentation" do
    test "active link has aria-current=page and non-color cue" do
      html = render_nav(admin_assigns("/admin/organizations"))
      doc = LazyHTML.from_fragment(html)

      link = LazyHTML.query(doc, ~s(a[aria-current="page"]))
      classes = LazyHTML.attribute(link, "class") |> List.first()

      # Non-color cue: bolder weight plus a filled background (no hue-only signal).
      assert classes =~ "font-semibold"
      assert classes =~ "bg-base-200"
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

    test "editor sees GTFS task links" do
      html = render_nav(editor_assigns("/"))
      assert html =~ "Routes"
      assert html =~ "Stops"
      assert html =~ "Import"
      assert html =~ "Export"
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

    test "renders exactly four navigation links" do
      html = render_station_sub_nav(%{})
      doc = LazyHTML.from_fragment(html)
      links = LazyHTML.query(doc, "#station-sub-nav nav a")
      assert Enum.count(links) == 4
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

      assert LazyHTML.query(doc, "#workspace-mode-option-map-reason") != []

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
