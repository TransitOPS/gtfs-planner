defmodule GtfsPlannerWeb.Gtfs.SettingsLiveTest do
  use GtfsPlannerWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Versions
  alias GtfsPlannerWeb.ComingSoon

  # The one allowlisted placeholder section, its catalog key and the scope the
  # catalog declares for it. Feed details, Agencies, Export defaults and Fares
  # left this list as their pages shipped; they are built pages now and are
  # asserted as Available entries.
  @placeholder_sections [
    %{slug: "feed-url", key: :feed_url, scope: :all_versions}
  ]

  @unknown_section_message "That settings section doesn’t exist. Choose one from the list below."

  @version_entry_keys [
    :feed_details,
    :agencies,
    :fares
  ]

  # Working pages first; the two placeholders sit last, under the Coming soon band.
  @all_version_entry_keys [
    :garages,
    :fleet,
    :export_defaults,
    :feed_url
  ]

  defp editor_setup(_context) do
    organization = organization_fixture()
    user = user_fixture()

    Accounts.create_user_org_membership(%{
      user_id: user.id,
      organization_id: organization.id,
      roles: ["pathways_studio_editor"]
    })

    version = gtfs_version_fixture(organization.id)

    %{user: user, organization: organization, version: version}
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

  defp settings_path(version_id), do: "/gtfs/#{version_id}/settings"
  defp section_path(version_id, slug), do: "/gtfs/#{version_id}/settings/#{slug}"

  defp entry_doc(doc, key), do: LazyHTML.query(doc, "#settings-entry-#{key}")

  defp text_of(doc, selector) do
    doc |> LazyHTML.query(selector) |> LazyHTML.text() |> String.trim()
  end

  # Text with the template's line breaks collapsed the way a browser renders them.
  defp words_of(doc, selector) do
    doc |> text_of(selector) |> String.split() |> Enum.join(" ")
  end

  # One overview entry: the title and destination of its row link, and whether it
  # carries the Coming soon badge. A working entry shows no status word at all.
  # Expected copy comes from the sitemap and the shared catalog.
  defp assert_entry(doc, key, title, href, availability) do
    entry = entry_doc(doc, key)

    assert Enum.count(LazyHTML.query(entry, "a")) == 1
    assert text_of(entry, "#settings-entry-#{key}-title") == title
    assert LazyHTML.attribute(LazyHTML.query(entry, "a"), "href") == [href]

    case availability do
      :working -> refute LazyHTML.text(entry) =~ "Coming soon"
      :coming_soon -> assert LazyHTML.text(entry) =~ "Coming soon"
    end
  end

  describe "overview" do
    setup :editor_setup

    test "an editor sees the three version and four all-version entries, with no Organization group",
         %{conn: conn, user: user, organization: organization, version: version} do
      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} = live(conn, settings_path(version.id))
      doc = LazyHTML.from_fragment(render(view))

      # One h1 on the page. The directory is the navigation, so there is no tab bar.
      assert Enum.count(LazyHTML.query(doc, "h1")) == 1
      assert text_of(doc, "h1") == "Settings"
      refute has_element?(view, "#settings-nav")

      # The two scope groups, in the sitemap's order, and no admin group. The
      # version group says which version a change applies to.
      assert Enum.count(LazyHTML.query(doc, "#settings-overview section")) == 2
      assert text_of(doc, "#settings-version h2") == "This version"

      assert words_of(doc, "#settings-version-summary") ==
               "Changes apply to #{version.name} only. Other versions keep their own."

      assert text_of(doc, "#settings-all-versions h2") == "All versions"
      refute has_element?(view, "#settings-organization")

      assert LazyHTML.attribute(LazyHTML.query(doc, "#settings-version li"), "id") ==
               Enum.map(@version_entry_keys, &"settings-entry-#{&1}")

      assert LazyHTML.attribute(LazyHTML.query(doc, "#settings-all-versions li"), "id") ==
               Enum.map(@all_version_entry_keys, &"settings-entry-#{&1}")

      assert_entry(
        doc,
        :feed_details,
        "Feed details",
        section_path(version.id, "feed-details"),
        :working
      )

      assert_entry(
        doc,
        :agencies,
        "Agencies",
        section_path(version.id, "agencies"),
        :working
      )

      assert text_of(doc, "#settings-entry-agencies-summary") ==
               "The agencies that operate your routes: names, websites and the timezone your schedules run in."

      assert_entry(doc, :fares, "Fares", section_path(version.id, "fares"), :working)

      assert_entry(
        doc,
        :export_defaults,
        "Export defaults",
        section_path(version.id, "export-defaults"),
        :working
      )

      # The design system renders each row's copy in spans, and a built page is a
      # working row: no Coming soon badge.
      assert words_of(doc, "#settings-entry-export_defaults-summary") ==
               "Choose how future exports are written."

      refute text_of(doc, "#settings-entry-export_defaults") =~ "Coming soon"

      assert_entry(
        doc,
        :feed_url,
        "Published feed URL",
        section_path(version.id, "feed-url"),
        :coming_soon
      )

      assert_entry(doc, :garages, "Garages", section_path(version.id, "garages"), :working)
      assert_entry(doc, :fleet, "Fleet", section_path(version.id, "fleet"), :working)
    end

    test "placeholder rows sit under a Coming soon band, after the working rows",
         %{conn: conn, user: user, organization: organization, version: version} do
      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} = live(conn, settings_path(version.id))
      doc = LazyHTML.from_fragment(render(view))

      # The version group has only working pages, so it needs no band.
      assert Enum.empty?(LazyHTML.query(doc, "#settings-version h3"))

      assert text_of(doc, "#settings-all-versions h3") == "Coming soon"

      # Export defaults is a built page, so the band holds the one remaining
      # placeholder and its row sits with the working rows above the band.
      assert LazyHTML.attribute(
               LazyHTML.query(doc, "#settings-all-versions ul:last-of-type li"),
               "id"
             ) == ["settings-entry-feed_url"]
    end

    test "each row is one link, so no control competes inside it",
         %{conn: conn, user: user, organization: organization, version: version} do
      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} = live(conn, settings_path(version.id))
      doc = LazyHTML.from_fragment(render(view))

      assert Enum.count(LazyHTML.query(doc, "#settings-overview li")) == 7
      assert Enum.count(LazyHTML.query(doc, "#settings-overview li > a")) == 7
      assert Enum.empty?(LazyHTML.query(doc, "#settings-overview li button"))
    end

    test "placeholder entries read their title and summary from the shared catalog",
         %{conn: conn, user: user, organization: organization, version: version} do
      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} = live(conn, settings_path(version.id))
      doc = LazyHTML.from_fragment(render(view))

      for %{key: key} <- @placeholder_sections do
        feature = ComingSoon.feature(key)

        assert text_of(doc, "#settings-entry-#{key}-title") == feature.title
        assert text_of(doc, "#settings-entry-#{key}-summary") == feature.summary
      end
    end

    test "the Fares entry carries the built page's copy and links to its workspace",
         %{conn: conn, user: user, organization: organization, version: version} do
      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} = live(conn, settings_path(version.id))
      doc = LazyHTML.from_fragment(render(view))

      # The reference copy the Coming soon entry used to carry, now owned by the
      # overview entry, and the slug destination `/settings/fares` unchanged.
      assert text_of(doc, "#settings-entry-fares-summary") ==
               "Group stops into fare zones, then set the fare rules that use them."

      assert LazyHTML.attribute(LazyHTML.query(doc, "#settings-entry-fares a"), "href") ==
               [section_path(version.id, "fares")]

      # No placeholder body renders inside a built entry.
      assert Enum.empty?(LazyHTML.query(doc, "#settings-entry-fares #coming-soon"))
      refute has_element?(view, "#settings-entry-fares #coming-soon-status")
    end

    test "an editor who is also an organization admin sees the Organization group last",
         %{conn: conn, organization: organization, version: version} do
      admin = member_with_roles(organization, ["pathways_studio_editor", "pathways_studio_admin"])
      conn = log_in_user(conn, admin, organization: organization)

      {:ok, view, _html} = live(conn, settings_path(version.id))
      doc = LazyHTML.from_fragment(render(view))

      assert LazyHTML.attribute(LazyHTML.query(doc, "#settings-overview section"), "id") ==
               ["settings-version", "settings-all-versions", "settings-organization"]

      assert text_of(doc, "#settings-organization h2") == "Organization"

      assert LazyHTML.attribute(LazyHTML.query(doc, "#settings-organization li"), "id") ==
               ["settings-entry-organization_name", "settings-entry-users"]

      assert_entry(
        doc,
        :organization_name,
        "Organization name",
        "/admin/users/organization-settings",
        :working
      )

      assert_entry(doc, :users, "Users", "/admin/users", :working)

      # The group is additive: the version and all-version entries are unchanged.
      assert LazyHTML.attribute(LazyHTML.query(doc, "#settings-all-versions li"), "id") ==
               Enum.map(@all_version_entry_keys, &"settings-entry-#{&1}")
    end
  end

  describe "placeholder sections" do
    setup :editor_setup

    for section <- @placeholder_sections do
      test "#{section.slug} renders the shared #{section.key} content with its scope",
           %{conn: conn, user: user, organization: organization, version: version} do
        conn = log_in_user(conn, user, organization: organization)

        {:ok, view, _html} = live(conn, section_path(version.id, unquote(section.slug)))
        doc = LazyHTML.from_fragment(render(view))

        feature = ComingSoon.feature(unquote(section.key))

        # The feature title is the page's only h1: Settings itself is not repeated.
        assert Enum.count(LazyHTML.query(doc, "h1")) == 1
        assert text_of(doc, "h1") == feature.title
        refute has_element?(view, "#settings-overview")

        assert text_of(doc, "#coming-soon-scope") ==
                 if(unquote(section.scope) == :version,
                   do: "This version: #{version.name}",
                   else: "All versions"
                 )

        assert LazyHTML.text(LazyHTML.query(doc, "#coming-soon")) =~ feature.summary

        assert Enum.count(LazyHTML.query(doc, "#coming-soon-sections li")) ==
                 length(feature.sections)

        assert has_element?(view, "#coming-soon-status", "Coming soon")

        # The way back is a "Settings" link above the heading, not a tab bar.
        refute has_element?(view, "#settings-nav")
        assert text_of(doc, "#settings-back") == "Settings"

        assert LazyHTML.attribute(LazyHTML.query(doc, "#settings-back"), "href") ==
                 [settings_path(version.id)]
      end
    end

    test "an unknown section slug returns to the overview",
         %{conn: conn, user: user, organization: organization, version: version} do
      conn = log_in_user(conn, user, organization: organization)

      for slug <- ["unknown", "garages-extra", "feed_details", "Garages"] do
        assert {:error,
                {:live_redirect, %{to: to, flash: %{"error" => @unknown_section_message}}}} =
                 live(conn, section_path(version.id, slug))

        assert to == settings_path(version.id)
      end
    end
  end

  describe "fares placement" do
    setup :editor_setup

    test "the Fares destination renders the workspace, not the Coming soon body",
         %{conn: conn, user: user, organization: organization, version: version} do
      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} = live(conn, section_path(version.id, "fares"))
      doc = LazyHTML.from_fragment(render(view))

      # The literal route resolves before `/settings/:section`, so this is the
      # workspace shell, which leads back to Settings instead of carrying its bar.
      assert text_of(doc, "h1") == "Fares"
      # An empty inventory shows the workspace's first-use state instead of the panel.
      assert has_element?(view, "#fare-zone-first-use")
      refute has_element?(view, "#coming-soon")

      assert LazyHTML.attribute(LazyHTML.query(doc, "#settings-back"), "href") ==
               [settings_path(version.id)]

      refute has_element?(view, "#settings-nav")
    end
  end

  describe "access" do
    setup :editor_setup

    test "members without the editor role cannot reach Settings",
         %{conn: conn, organization: organization, version: version} do
      for roles <- [[], ["pathways_studio_admin"]] do
        member = member_with_roles(organization, roles)
        member_conn = log_in_user(conn, member, organization: organization)

        for path <- [settings_path(version.id), section_path(version.id, "fares")] do
          assert {:error, {:redirect, %{to: "/admin/organizations"}}} = live(member_conn, path)
        end
      end
    end

    test "an editor without the organization-admin role is denied the admin pages",
         %{conn: conn, user: user, organization: organization} do
      conn = log_in_user(conn, user, organization: organization)

      assert {:error, {:redirect, %{to: "/admin/organizations"}}} = live(conn, "/admin/users")
    end

    test "unauthenticated visits follow the existing login redirect", %{version: version} do
      conn = build_conn() |> init_test_session(%{})

      for path <- [settings_path(version.id), section_path(version.id, "agencies")] do
        assert redirected_to(get(conn, path)) == "/users/log_in"
      end
    end

    test "missing, staging and foreign-organization versions redirect to the dashboard",
         %{conn: conn, user: user, organization: organization} do
      conn = log_in_user(conn, user, organization: organization)

      {:ok, staging} = Versions.create_staging_gtfs_version(organization.id, %{name: "Staging"})

      other_organization = organization_fixture()
      foreign_version = gtfs_version_fixture(other_organization.id)

      for version_id <- [Ecto.UUID.generate(), staging.id, foreign_version.id] do
        assert {:error, {:redirect, %{to: "/", flash: %{"error" => "GTFS version not found"}}}} =
                 live(conn, settings_path(version_id))

        assert {:error, {:redirect, %{to: "/", flash: %{"error" => "GTFS version not found"}}}} =
                 live(conn, section_path(version_id, "feed-details"))
      end
    end
  end

  describe "version switching" do
    setup :editor_setup

    test "an explicit selection keeps the overview",
         %{conn: conn, user: user, organization: organization, version: version} do
      {:ok, other_version} =
        Versions.create_gtfs_version(organization.id, %{name: "Second Version"})

      conn = log_in_user(conn, user, organization: organization)
      selected_version_id = to_string(other_version.id)

      {:ok, view, _html} = live(conn, settings_path(version.id))

      render_hook(view, "switch_gtfs_version", %{"version" => selected_version_id})

      assert_push_event(view, "gtfs_version_selected", %{version_id: ^selected_version_id})
      assert_redirect(view, settings_path(other_version.id))
    end

    test "an explicit selection keeps the section",
         %{conn: conn, user: user, organization: organization, version: version} do
      {:ok, other_version} =
        Versions.create_gtfs_version(organization.id, %{name: "Second Version"})

      conn = log_in_user(conn, user, organization: organization)
      selected_version_id = to_string(other_version.id)

      for %{slug: slug} <- @placeholder_sections do
        {:ok, view, _html} = live(conn, section_path(version.id, slug))

        render_hook(view, "switch_gtfs_version", %{"version" => selected_version_id})

        assert_push_event(view, "gtfs_version_selected", %{version_id: ^selected_version_id})
        assert_redirect(view, section_path(other_version.id, slug))
      end
    end

    test "a stored selection navigates to the overview and to the same section",
         %{conn: conn, user: user, organization: organization, version: version} do
      {:ok, other_version} =
        Versions.create_gtfs_version(organization.id, %{name: "Second Version"})

      conn = log_in_user(conn, user, organization: organization)
      selected_version_id = to_string(other_version.id)

      {:ok, overview, _html} = live(conn, settings_path(version.id))

      render_hook(overview, "gtfs_version_loaded", %{"version_id" => selected_version_id})
      assert_redirect(overview, settings_path(other_version.id))
      refute_push_event(overview, "gtfs_version_selected", %{version_id: _})

      {:ok, section, _html} = live(conn, section_path(version.id, "feed-url"))

      render_hook(section, "gtfs_version_loaded", %{"version_id" => selected_version_id})
      assert_redirect(section, section_path(other_version.id, "feed-url"))
      refute_push_event(section, "gtfs_version_selected", %{version_id: _})
    end

    test "a stored selection of the current version changes nothing",
         %{conn: conn, user: user, organization: organization, version: version} do
      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} = live(conn, settings_path(version.id))

      for version_id <- [to_string(version.id), nil] do
        render_hook(view, "gtfs_version_loaded", %{"version_id" => version_id})
        refute_redirected(view)
      end
    end

    test "staging, foreign and absent selections neither navigate nor report a selection",
         %{conn: conn, user: user, organization: organization, version: version} do
      {:ok, staging} = Versions.create_staging_gtfs_version(organization.id, %{name: "Staging"})

      other_organization = organization_fixture()
      foreign_version = gtfs_version_fixture(other_organization.id)

      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, section_path(version.id, "feed-details"))

      for version_id <- [staging.id, foreign_version.id, Ecto.UUID.generate()] do
        render_hook(view, "switch_gtfs_version", %{"version" => to_string(version_id)})
        refute_push_event(view, "gtfs_version_selected", %{version_id: _})
        refute_redirected(view)
      end
    end
  end

  describe "product filtering (ProductSurfaces)" do
    # The seven Settings sections a Pathways organization hides (spec R5).
    defp pathways_hidden_keys do
      [:feed_details, :agencies, :fares, :export_defaults, :feed_url, :garages, :fleet]
    end

    defp product_org_with_version(product, roles) do
      organization = organization_fixture(%{product: product})
      member = member_with_roles(organization, roles)
      version = gtfs_version_fixture(organization.id)
      %{organization: organization, member: member, version: version}
    end

    test "a Pathways editor+admin sees only the Organization group",
         %{conn: conn} do
      %{organization: organization, member: admin, version: version} =
        product_org_with_version(:pathways, [
          "pathways_studio_editor",
          "pathways_studio_admin"
        ])

      conn = log_in_user(conn, admin, organization: organization)
      {:ok, view, _html} = live(conn, settings_path(version.id))
      doc = LazyHTML.from_fragment(render(view))

      for key <- pathways_hidden_keys() do
        refute has_element?(view, "#settings-entry-#{key}")
      end

      refute has_element?(view, "#settings-empty")

      assert LazyHTML.attribute(LazyHTML.query(doc, "#settings-overview section"), "id") ==
               ["settings-organization"]

      assert text_of(doc, "#settings-organization h2") == "Organization"

      assert_entry(
        doc,
        :organization_name,
        "Organization name",
        "/admin/users/organization-settings",
        :working
      )

      assert_entry(doc, :users, "Users", "/admin/users", :working)
    end

    test "a Pathways editor without admin sees the empty state and no groups",
         %{conn: conn} do
      %{organization: organization, member: editor, version: version} =
        product_org_with_version(:pathways, ["pathways_studio_editor"])

      conn = log_in_user(conn, editor, organization: organization)
      {:ok, view, _html} = live(conn, settings_path(version.id))
      doc = LazyHTML.from_fragment(render(view))

      assert has_element?(view, "#settings-empty")
      assert text_of(doc, "#settings-empty h2") == "No settings are available for your role"

      # One next step, into a page a Pathways editor can use.
      assert LazyHTML.attribute(LazyHTML.query(doc, "#settings-empty-action"), "href") ==
               ["/gtfs/#{version.id}/stops"]

      refute has_element?(view, "#settings-overview")
    end

    test "a Planner editor+admin sees every entry", %{conn: conn} do
      %{organization: organization, member: admin, version: version} =
        product_org_with_version(:planner, [
          "pathways_studio_editor",
          "pathways_studio_admin"
        ])

      conn = log_in_user(conn, admin, organization: organization)
      {:ok, view, _html} = live(conn, settings_path(version.id))
      doc = LazyHTML.from_fragment(render(view))

      for key <- pathways_hidden_keys() do
        assert has_element?(view, "#settings-entry-#{key}")
      end

      assert LazyHTML.attribute(LazyHTML.query(doc, "#settings-overview section"), "id") ==
               ["settings-version", "settings-all-versions", "settings-organization"]
    end

    test "hidden pages stay reachable for a Pathways editor (hidden, not denied)",
         %{conn: conn} do
      %{organization: organization, member: editor, version: version} =
        product_org_with_version(:pathways, ["pathways_studio_editor"])

      conn = log_in_user(conn, editor, organization: organization)

      for path <- [
            "/settings/fleet",
            "/settings/garages",
            "/settings/fares",
            "/settings/feed-details",
            "/settings/agencies",
            "/blocks",
            "/flex"
          ] do
        assert {:ok, view, _html} = live(conn, "/gtfs/#{version.id}#{path}")
        assert has_element?(view, "h1")
        refute has_element?(view, ~s([id^="settings-tab-"])), "#{path} shows hidden settings tabs"
        refute has_element?(view, "#flash-error"), "#{path} shows an error flash"
      end
    end
  end
end
