defmodule GtfsPlannerWeb.Gtfs.FeedDetailsLiveTest do
  use GtfsPlannerWeb.ConnCase, async: true

  import Ecto.Query
  import Phoenix.LiveViewTest
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Gtfs.AuditContext
  alias GtfsPlanner.Gtfs.FeedInfo
  alias GtfsPlanner.Gtfs.FeedSettings
  alias GtfsPlanner.Repo
  alias GtfsPlanner.Versions

  @summary_subtitle "Publisher information for this version—not the contact details riders use."

  # The publisher name, website and language are required; the rest is optional,
  # so `default_lang` is deliberately absent and reads "Not set" (AC-1).
  @feed_info_attrs %{
    feed_publisher_name: "Browser Regional Partnership",
    feed_publisher_url: "https://example.test/data",
    feed_lang: "en",
    feed_start_date: ~D[2026-09-01],
    feed_end_date: ~D[2026-12-31],
    feed_version: "2026-autumn",
    feed_contact_email: "data@example.test",
    feed_contact_url: "https://example.test/data/contact"
  }

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

  defp feed_details_path(version_id), do: "/gtfs/#{version_id}/settings/feed-details"
  defp settings_path(version_id), do: "/gtfs/#{version_id}/settings"
  defp agencies_path(version_id), do: "/gtfs/#{version_id}/settings/agencies"

  # The row is written by the application's own writer, so the case exercises the
  # stored shape a real save produces (INV-5) instead of a private insert.
  defp save_feed_info(user, organization, version, attrs) do
    audit = %AuditContext{
      organization_id: organization.id,
      gtfs_version_id: version.id,
      actor_id: user.id,
      actor_email: user.email
    }

    {:ok, feed_info} = FeedSettings.save_feed_info(audit, attrs, nil)
    feed_info
  end

  # A row as an import leaves it. The editor changeset refuses a value outside the
  # list (`default_lang: "en-US"` is a locale, not an ISO 639-1 code, and `bh` is
  # the only two-letter code the list omits), so the base changeset — the import
  # path R12 keeps untouched — is the only way such a row exists for the page to
  # read back.
  defp import_feed_info(organization, version, attrs) do
    %FeedInfo{organization_id: organization.id, gtfs_version_id: version.id}
    |> FeedInfo.changeset(attrs)
    |> Repo.insert!()
  end

  defp text_of(doc, selector) do
    doc |> LazyHTML.query(selector) |> LazyHTML.text() |> String.trim()
  end

  defp texts_of(doc, selector) do
    doc
    |> LazyHTML.query(selector)
    |> Enum.map(&(&1 |> LazyHTML.text() |> String.trim()))
  end

  defp section_labels(doc, section), do: texts_of(doc, "#{section} dt")
  defp section_values(doc, section), do: texts_of(doc, "#{section} dd")

  describe "summary" do
    setup :editor_setup

    test "renders the three sections with stored values and Not set for the blanks",
         %{conn: conn, user: user, organization: organization, version: version} do
      save_feed_info(user, organization, version, @feed_info_attrs)
      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} = live(conn, feed_details_path(version.id))
      doc = LazyHTML.from_fragment(render(view))

      assert has_element?(view, "#feed-details-summary")
      refute has_element?(view, "#feed-details-empty")
      refute has_element?(view, "#coming-soon-status")

      assert Enum.count(LazyHTML.query(doc, "h1")) == 1
      assert text_of(doc, "h1") == "Feed details"
      assert text_of(doc, "h1 + p") == @summary_subtitle

      # The prototype's section order: Publisher, Validity and version, Technical
      # contact.
      assert LazyHTML.attribute(LazyHTML.query(doc, "#feed-details-summary section"), "id") ==
               ["feed-details-publisher", "feed-details-validity", "feed-details-contact"]

      assert texts_of(doc, "#feed-details-summary section h2") == [
               "Publisher",
               "Validity and version",
               "Technical contact"
             ]

      assert section_labels(doc, "#feed-details-publisher") == [
               "Name",
               "Website",
               "Feed language",
               "Default language"
             ]

      assert section_values(doc, "#feed-details-publisher") == [
               "Browser Regional Partnership",
               "https://example.test/data",
               "English (en)",
               "Not set"
             ]

      assert section_labels(doc, "#feed-details-validity") == [
               "Valid from",
               "Valid through",
               "Feed version"
             ]

      assert section_values(doc, "#feed-details-validity") == [
               "Sep 1, 2026",
               "Dec 31, 2026",
               "2026-autumn"
             ]

      assert section_labels(doc, "#feed-details-contact") == ["Email", "Website"]

      assert section_values(doc, "#feed-details-contact") == [
               "data@example.test",
               "https://example.test/data/contact"
             ]

      assert has_element?(view, "#feed-details-publisher", "Details set")
    end

    test "labels a language outside the list as stored and mul as Multilingual",
         %{conn: conn, user: user, organization: organization, version: version} do
      import_feed_info(
        organization,
        version,
        Map.merge(@feed_info_attrs, %{feed_lang: "mul", default_lang: "en-US"})
      )

      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} = live(conn, feed_details_path(version.id))

      assert has_element?(view, "#feed-details-publisher", "Multilingual (mul)")
      assert has_element?(view, "#feed-details-publisher", "en-US")
    end

    test "renders the aside notes and the Settings bar",
         %{conn: conn, user: user, organization: organization, version: version} do
      save_feed_info(user, organization, version, @feed_info_attrs)
      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} = live(conn, feed_details_path(version.id))
      doc = LazyHTML.from_fragment(render(view))

      assert texts_of(doc, "#feed-details-summary aside h2") == [
               "One feed, one publisher",
               "For data consumers"
             ]

      assert text_of(doc, "#feed-details-summary aside") =~
               "A regional partnership can publish a dataset containing several agencies."

      assert text_of(doc, "#feed-details-summary aside") =~
               "These details are included when this version is exported. Saving does not publish the feed."

      assert LazyHTML.attribute(
               LazyHTML.query(doc, "#feed-details-manage-agencies"),
               "href"
             ) == [agencies_path(version.id)]

      assert LazyHTML.attribute(
               LazyHTML.query(doc, "#settings-nav a[aria-current='page']"),
               "href"
             ) == [feed_details_path(version.id)]
    end
  end

  describe "empty state" do
    setup :editor_setup

    test "a version without feed info shows the empty state and mounts without writing",
         %{conn: conn, user: user, organization: organization, version: version} do
      assert Repo.aggregate(from(f in FeedInfo, where: f.gtfs_version_id == ^version.id), :count) ==
               0

      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} = live(conn, feed_details_path(version.id))

      assert has_element?(view, "#feed-details-empty", "Introduce your feed")

      assert has_element?(
               view,
               "#feed-details-empty",
               "Add the publisher, website, and language."
             )

      refute has_element?(view, "#feed-details-summary")
      refute has_element?(view, "#coming-soon-status")

      # No action button is offered until the drawer step adds one.
      refute has_element?(view, "#feed-details-empty button")

      assert Repo.aggregate(from(f in FeedInfo, where: f.gtfs_version_id == ^version.id), :count) ==
               0
    end

    test "only the version's own row is read",
         %{conn: conn, user: user, organization: organization, version: version} do
      other_version = gtfs_version_fixture(organization.id)
      save_feed_info(user, organization, other_version, @feed_info_attrs)

      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} = live(conn, feed_details_path(version.id))

      assert has_element?(view, "#feed-details-empty")
      refute has_element?(view, "#feed-details-summary")
    end
  end

  describe "settings overview entry" do
    setup :editor_setup

    test "lists Feed details as an Available page linking to its literal route",
         %{conn: conn, user: user, organization: organization, version: version} do
      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} = live(conn, settings_path(version.id))
      doc = LazyHTML.from_fragment(render(view))

      entry = LazyHTML.query(doc, "#settings-entry-feed_details")

      assert LazyHTML.attribute(LazyHTML.query(entry, "a"), "href") == [
               feed_details_path(version.id)
             ]

      assert text_of(doc, "#settings-entry-feed_details a") == "Feed details"

      assert text_of(doc, "#settings-entry-feed_details p") ==
               "Describe this version’s feed for data consumers."

      assert has_element?(view, "#settings-entry-feed_details", "Available")

      assert LazyHTML.attribute(LazyHTML.query(doc, "#settings-version li"), "id") ==
               ["settings-entry-feed_details", "settings-entry-agencies", "settings-entry-fares"]
    end
  end

  describe "version switching" do
    setup :editor_setup

    test "an explicit selection of another published version keeps the page",
         %{conn: conn, user: user, organization: organization, version: version} do
      {:ok, other_version} =
        Versions.create_gtfs_version(organization.id, %{name: "Second Version"})

      conn = log_in_user(conn, user, organization: organization)
      selected_version_id = to_string(other_version.id)

      {:ok, view, _html} = live(conn, feed_details_path(version.id))

      render_hook(view, "switch_gtfs_version", %{"version" => selected_version_id})

      assert_push_event(view, "gtfs_version_selected", %{version_id: ^selected_version_id})
      assert_redirect(view, feed_details_path(other_version.id))
    end

    test "a stored selection of another published version navigates to the same page",
         %{conn: conn, user: user, organization: organization, version: version} do
      {:ok, other_version} =
        Versions.create_gtfs_version(organization.id, %{name: "Second Version"})

      conn = log_in_user(conn, user, organization: organization)
      selected_version_id = to_string(other_version.id)

      {:ok, view, _html} = live(conn, feed_details_path(version.id))

      render_hook(view, "gtfs_version_loaded", %{"version_id" => selected_version_id})
      assert_redirect(view, feed_details_path(other_version.id))
      refute_push_event(view, "gtfs_version_selected", %{version_id: _})
    end

    test "staging, foreign, absent and current selections change nothing",
         %{conn: conn, user: user, organization: organization, version: version} do
      {:ok, staging} = Versions.create_staging_gtfs_version(organization.id, %{name: "Staging"})

      other_organization = organization_fixture()
      foreign_version = gtfs_version_fixture(other_organization.id)

      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, feed_details_path(version.id))

      # The current version is included through both events: the switcher hook
      # returns before it sends anything for the version it already shows, so a
      # selection of it is a no-op rather than a navigation to the same URL.
      for version_id <- [
            to_string(staging.id),
            to_string(foreign_version.id),
            Ecto.UUID.generate(),
            to_string(version.id),
            nil
          ] do
        render_hook(view, "switch_gtfs_version", %{"version" => version_id})
        refute_redirected(view)

        render_hook(view, "gtfs_version_loaded", %{"version_id" => version_id})
        refute_redirected(view)
      end

      refute_push_event(view, "gtfs_version_selected", %{version_id: _})
    end
  end

  describe "access" do
    setup :editor_setup

    test "members without the editor role cannot reach the page",
         %{conn: conn, organization: organization, version: version} do
      for roles <- [[], ["pathways_studio_admin"]] do
        member = member_with_roles(organization, roles)
        member_conn = log_in_user(conn, member, organization: organization)

        assert {:error, {:redirect, %{to: "/admin/organizations"}}} =
                 live(member_conn, feed_details_path(version.id))
      end
    end

    test "an unauthenticated visit follows the existing login redirect", %{version: version} do
      conn = build_conn() |> init_test_session(%{})

      assert redirected_to(get(conn, feed_details_path(version.id))) == "/users/log_in"
    end

    test "missing, staging and foreign-organization versions redirect to the dashboard",
         %{conn: conn, user: user, organization: organization} do
      conn = log_in_user(conn, user, organization: organization)

      {:ok, staging} = Versions.create_staging_gtfs_version(organization.id, %{name: "Staging"})

      other_organization = organization_fixture()
      foreign_version = gtfs_version_fixture(other_organization.id)

      for version_id <- [Ecto.UUID.generate(), staging.id, foreign_version.id] do
        assert {:error, {:redirect, %{to: "/", flash: %{"error" => "GTFS version not found"}}}} =
                 live(conn, feed_details_path(version_id))
      end
    end
  end
end
