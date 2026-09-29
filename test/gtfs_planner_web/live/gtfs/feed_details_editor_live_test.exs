defmodule GtfsPlannerWeb.Gtfs.FeedDetailsEditorLiveTest do
  use GtfsPlannerWeb.ConnCase, async: true

  import Ecto.Query
  import Phoenix.LiveViewTest
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Gtfs.AuditContext
  alias GtfsPlanner.Gtfs.DisplayClock
  alias GtfsPlanner.Gtfs.FeedInfo
  alias GtfsPlanner.Gtfs.FeedSettings
  alias GtfsPlanner.Repo
  alias GtfsPlanner.Versions.GtfsVersion

  @url_message "Enter a full web address, starting with https:// or http://."

  # The nine drawer fields with values a valid save accepts. Every case merges
  # over these so the select values are options the form actually offers.
  @drawer_params %{
    "feed_publisher_name" => "Metro Transit",
    "feed_publisher_url" => "https://metro.example",
    "feed_lang" => "en",
    "default_lang" => "es",
    "feed_start_date" => "2026-01-01",
    "feed_end_date" => "2026-06-30",
    "feed_version" => "2026-spring",
    "feed_contact_email" => "data@metro.example",
    "feed_contact_url" => "https://metro.example/contact"
  }

  @stored_attrs %{
    feed_publisher_name: "Metro Transit",
    feed_publisher_url: "https://metro.example",
    feed_lang: "en",
    default_lang: "es",
    feed_start_date: ~D[2026-01-01],
    feed_end_date: ~D[2026-06-30],
    feed_version: "2026-spring",
    feed_contact_email: "data@metro.example",
    feed_contact_url: "https://metro.example/contact"
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

  defp feed_details_path(version_id), do: "/gtfs/#{version_id}/settings/feed-details"
  defp settings_path(version_id), do: "/gtfs/#{version_id}/settings"

  defp editor_view(conn, user, organization, version) do
    conn = log_in_user(conn, user, organization: organization)
    live(conn, feed_details_path(version.id))
  end

  # The row is written by the application's own writer, so each case starts from
  # the stored shape a real save produces (INV-5).
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

  # A row as an import leaves it: the editor changeset refuses this URL, and the
  # base changeset is the only way such a row exists for the drawer to load.
  defp import_feed_info(organization, version, attrs) do
    %FeedInfo{organization_id: organization.id, gtfs_version_id: version.id}
    |> FeedInfo.changeset(attrs)
    |> Repo.insert!()
  end

  defp feed_info_row(organization, version) do
    FeedSettings.get_feed_info(organization.id, version.id)
  end

  defp feed_info_rows(organization) do
    Repo.aggregate(from(f in FeedInfo, where: f.organization_id == ^organization.id), :count)
  end

  defp open_drawer(view, opener \\ "#feed-details-set") do
    view |> element(opener) |> render_click()
  end

  defp submit(view, attrs) do
    view
    |> form("#feed-details-form", feed_info: Map.merge(@drawer_params, attrs))
    |> render_submit()
  end

  defp submit_fields(view, attrs) do
    view |> form("#feed-details-form", feed_info: attrs) |> render_submit()
  end

  defp change(view, attrs) do
    view |> form("#feed-details-form", feed_info: attrs) |> render_change()
  end

  describe "create" do
    setup :editor_setup

    test "Set up feed details creates the row, closes the drawer, flashes and shows the summary",
         %{conn: conn, user: user, organization: organization, version: version} do
      {:ok, view, _html} = editor_view(conn, user, organization, version)

      assert has_element?(view, "#feed-details-empty", "No feed details yet")
      assert has_element?(view, "#feed-details-set", "Set up feed details")
      refute has_element?(view, "#feed-details-edit")
      assert has_element?(view, "#feed-details-drawer-overlay[data-open='false']")

      open_drawer(view)

      assert has_element?(view, "#feed-details-drawer-overlay[data-open='true']")
      assert has_element?(view, "#feed-details-drawer-title", "Set up feed details")
      assert has_element?(view, "#feed-details-form-panel[phx-hook='FormErrorFocus']")
      assert has_element?(view, "#feed-details-form")

      # The opener id travels to the drawer so the OverlayDialog hook can return
      # focus to the control that was clicked.
      assert has_element?(
               view,
               "#feed-details-drawer-overlay[data-return-focus-id='feed-details-set']"
             )

      # Opening writes nothing: the row appears only on a successful save (AC-2).
      assert feed_info_rows(organization) == 0

      # The save token lives in socket assigns, never in the form (CR-9).
      refute has_element?(view, "#feed-details-form input[name*='updated_at']")

      submit(view, %{})

      assert feed_info_rows(organization) == 1

      row = feed_info_row(organization, version)
      assert row.feed_publisher_name == "Metro Transit"
      assert row.feed_lang == "en"
      assert row.default_lang == "es"
      assert row.feed_start_date == ~D[2026-01-01]
      assert row.feed_end_date == ~D[2026-06-30]
      assert row.feed_version == "2026-spring"
      assert row.feed_contact_email == "data@metro.example"

      assert has_element?(view, "#feed-details-drawer-overlay[data-open='false']")
      assert has_element?(view, "#flash-info", "Feed details saved.")
      assert has_element?(view, "#feed-details-summary")
      assert has_element?(view, "#feed-details-publisher dl", "Metro Transit")
      assert has_element?(view, "#feed-details-validity dl", "2026-spring")
      refute has_element?(view, "#feed-details-empty")
      assert has_element?(view, "#feed-details-edit", "Edit feed details")
    end
  end

  describe "edit" do
    setup :editor_setup

    test "Edit feed details saves an updated publisher name to the database",
         %{conn: conn, user: user, organization: organization, version: version} do
      save_feed_info(user, organization, version, @stored_attrs)

      {:ok, view, _html} = editor_view(conn, user, organization, version)

      assert has_element?(view, "#feed-details-edit", "Edit feed details")
      refute has_element?(view, "#feed-details-set")

      open_drawer(view, "#feed-details-edit")

      assert has_element?(view, "#feed-details-drawer-title", "Edit feed details")
      assert has_element?(view, "#feed_info_feed_publisher_name[value='Metro Transit']")
      assert has_element?(view, "#feed_info_feed_lang option[value='en'][selected]")

      assert has_element?(
               view,
               "#feed-details-drawer-overlay[data-return-focus-id='feed-details-edit']"
             )

      assert feed_info_rows(organization) == 1

      submit_fields(view, %{"feed_publisher_name" => "Metro Transit Authority"})

      assert feed_info_rows(organization) == 1

      row = feed_info_row(organization, version)
      assert row.feed_publisher_name == "Metro Transit Authority"
      # The untouched fields keep the stored values.
      assert row.feed_version == "2026-spring"
      assert row.feed_contact_url == "https://metro.example/contact"

      assert has_element?(view, "#feed-details-drawer-overlay[data-open='false']")
      assert has_element?(view, "#flash-info", "Feed details saved.")
      assert has_element?(view, "#feed-details-summary", "Metro Transit Authority")
    end

    test "an untouched imported value outside the editor rules does not block a name change",
         %{conn: conn, user: user, organization: organization, version: version} do
      import_feed_info(
        organization,
        version,
        Map.put(@stored_attrs, :feed_publisher_url, "www.example.com")
      )

      {:ok, view, _html} = editor_view(conn, user, organization, version)
      open_drawer(view, "#feed-details-edit")

      submit_fields(view, %{"feed_publisher_name" => "Metro Transit Authority"})

      assert has_element?(view, "#feed-details-drawer-overlay[data-open='false']")
      refute has_element?(view, "#feed-details-form-error")

      row = feed_info_row(organization, version)
      assert row.feed_publisher_name == "Metro Transit Authority"
      assert row.feed_publisher_url == "www.example.com"
    end
  end

  describe "validation" do
    setup :editor_setup

    test "a schemeless publisher URL shows its field error, focuses it and writes nothing",
         %{conn: conn, user: user, organization: organization, version: version} do
      {:ok, view, _html} = editor_view(conn, user, organization, version)
      open_drawer(view)

      submit(view, %{"feed_publisher_url" => "www.example.com"})

      assert has_element?(
               view,
               "#feed-details-form-error",
               "Nothing was saved. Check the highlighted fields."
             )

      assert has_element?(view, "#feed_info_feed_publisher_url-error", @url_message)
      assert has_element?(view, "#feed_info_feed_publisher_url[aria-invalid='true']")

      assert_push_event(view, "focus_form_error", %{
        form_id: "feed-details-form",
        fallback_id: "feed-details-form-error"
      })

      assert has_element?(view, "#feed-details-drawer-overlay[data-open='true']")
      assert feed_info_rows(organization) == 0
    end

    test "an end date before the start date shows its field error and writes nothing",
         %{conn: conn, user: user, organization: organization, version: version} do
      {:ok, view, _html} = editor_view(conn, user, organization, version)
      open_drawer(view)

      submit(view, %{
        "feed_start_date" => "2026-09-01",
        "feed_end_date" => "2026-08-01"
      })

      assert has_element?(
               view,
               "#feed_info_feed_end_date-error",
               "Choose a date on or after Sep 1, 2026, the valid-from date."
             )

      assert_push_event(view, "focus_form_error", %{
        form_id: "feed-details-form",
        fallback_id: "feed-details-form-error"
      })

      assert feed_info_rows(organization) == 0
    end

    test "a blank publisher name shows its field error and writes nothing",
         %{conn: conn, user: user, organization: organization, version: version} do
      {:ok, view, _html} = editor_view(conn, user, organization, version)
      open_drawer(view)

      submit(view, %{"feed_publisher_name" => ""})

      assert has_element?(
               view,
               "#feed_info_feed_publisher_name-error",
               "Enter the publisher name."
             )

      assert_push_event(view, "focus_form_error", %{
        form_id: "feed-details-form",
        fallback_id: "feed-details-form-error"
      })

      assert feed_info_rows(organization) == 0
    end

    test "every refused rule says what to enter",
         %{conn: conn, user: user, organization: organization, version: version} do
      {:ok, view, _html} = editor_view(conn, user, organization, version)
      open_drawer(view)

      submit(view, %{
        "feed_publisher_name" => "",
        "feed_publisher_url" => "",
        "feed_lang" => "",
        "default_lang" => "es",
        "feed_version" => String.duplicate("v", 256),
        "feed_contact_email" => "data example",
        "feed_contact_url" => "example.com"
      })

      for {field, message} <- [
            {"feed_publisher_name", "Enter the publisher name."},
            {"feed_publisher_url", "Enter the publisher website."},
            {"feed_lang", "Choose the feed language."},
            {"feed_version", "Use 255 characters or fewer."},
            {"feed_contact_email", "Enter an email address, such as data@agency.org."},
            {"feed_contact_url", @url_message}
          ] do
        assert has_element?(view, "#feed_info_#{field}-error", message)
      end

      assert feed_info_rows(organization) == 0
    end

    test "a failed update leaves the stored row unchanged",
         %{conn: conn, user: user, organization: organization, version: version} do
      save_feed_info(user, organization, version, @stored_attrs)

      {:ok, view, _html} = editor_view(conn, user, organization, version)
      open_drawer(view, "#feed-details-edit")

      submit_fields(view, %{
        "feed_publisher_name" => "Rewrite",
        "feed_start_date" => "2026-09-01",
        "feed_end_date" => "2026-08-01"
      })

      assert has_element?(view, "#feed-details-form-error")
      assert feed_info_rows(organization) == 1
      assert feed_info_row(organization, version).feed_publisher_name == "Metro Transit"
      assert feed_info_row(organization, version).feed_end_date == ~D[2026-06-30]
    end

    test "typing in one field shows that field's error and leaves other fields alone",
         %{conn: conn, user: user, organization: organization, version: version} do
      {:ok, view, _html} = editor_view(conn, user, organization, version)
      open_drawer(view)

      # The browser marks a field the editor has not focused with `_unused_`,
      # which is what keeps an untouched blank field quiet. These params carry
      # the marker so the case observes the same contract a keystroke does.
      render_change(view, "validate", %{
        "feed_info" => %{
          "feed_publisher_name" => "",
          "_unused_feed_publisher_name" => "",
          "feed_publisher_url" => "www.example.com",
          "feed_lang" => "en"
        }
      })

      assert has_element?(view, "#feed_info_feed_publisher_url-error", @url_message)
      # Validation on change is not a save attempt, so the banner stays away.
      refute has_element?(view, "#feed-details-form-error")
      refute has_element?(view, "#feed_info_feed_publisher_name-error")
      refute has_element?(view, "#feed_info_feed_lang-error")
      assert feed_info_rows(organization) == 0
    end
  end

  describe "language selects" do
    setup :editor_setup

    test "choosing mul shows the translations note and only the feed language offers mul",
         %{conn: conn, user: user, organization: organization, version: version} do
      {:ok, view, _html} = editor_view(conn, user, organization, version)
      open_drawer(view)

      refute has_element?(view, "#feed-details-mul-note")

      assert has_element?(view, "#feed_info_feed_lang option[value='mul']")
      refute has_element?(view, "#feed_info_default_lang option[value='mul']")

      change(view, %{"feed_lang" => "mul"})

      assert has_element?(view, "#feed-details-mul-note", "Include translations with this feed")
      assert has_element?(view, "#feed_info_feed_lang option[value='mul'][selected]")

      assert has_element?(
               view,
               "#feed-details-mul-note",
               "Selecting Multilingual does not create translations."
             )

      # Choosing another language hides the note again.
      change(view, %{"feed_lang" => "en"})
      refute has_element?(view, "#feed-details-mul-note")
    end

    test "a stored default language outside the list stays selected",
         %{conn: conn, user: user, organization: organization, version: version} do
      import_feed_info(organization, version, Map.put(@stored_attrs, :default_lang, "en-US"))

      {:ok, view, _html} = editor_view(conn, user, organization, version)
      open_drawer(view, "#feed-details-edit")

      assert has_element?(view, "#feed_info_default_lang option[value='en-US'][selected]")
    end
  end

  describe "use date label" do
    setup :editor_setup

    test "the date-label action fills the version's date and never fills it on its own",
         %{conn: conn, user: user, organization: organization, version: version} do
      today = Date.to_iso8601(DisplayClock.today(organization.id, version.id).date)

      {:ok, view, _html} = editor_view(conn, user, organization, version)
      open_drawer(view)

      # No version carries a zone, so DisplayClock resolves UTC for the label.
      assert has_element?(view, "#feed_info_feed_version-help", "such as #{today} or")
      refute has_element?(view, "#feed_info_feed_version[value='#{today}']")

      view |> element("#feed-details-use-date-label") |> render_click()

      assert has_element?(view, "#feed_info_feed_version[value='#{today}']")
      assert feed_info_rows(organization) == 0
    end

    test "a stored label is left alone until the action is used",
         %{conn: conn, user: user, organization: organization, version: version} do
      save_feed_info(user, organization, version, @stored_attrs)
      today = Date.to_iso8601(DisplayClock.today(organization.id, version.id).date)

      {:ok, view, _html} = editor_view(conn, user, organization, version)
      open_drawer(view, "#feed-details-edit")

      assert has_element?(view, "#feed_info_feed_version[value='2026-spring']")

      view |> element("#feed-details-use-date-label") |> render_click()

      assert has_element?(view, "#feed_info_feed_version[value='#{today}']")
      refute has_element?(view, "#feed_info_feed_version[value='2026-spring']")
      # Filling the label is not a save: the stored row keeps its own label.
      assert feed_info_row(organization, version).feed_version == "2026-spring"
    end

    test "the action keeps the rest of the draft",
         %{conn: conn, user: user, organization: organization, version: version} do
      {:ok, view, _html} = editor_view(conn, user, organization, version)
      open_drawer(view)

      change(view, %{
        "feed_publisher_name" => "Draft Partnership",
        "feed_publisher_url" => "https://draft.example"
      })

      view |> element("#feed-details-use-date-label") |> render_click()

      assert has_element?(view, "#feed_info_feed_publisher_name[value='Draft Partnership']")
      assert has_element?(view, "#feed_info_feed_publisher_url[value='https://draft.example']")
      refute has_element?(view, "#feed-details-form-error")
      assert feed_info_rows(organization) == 0
    end
  end

  describe "conflict" do
    setup :editor_setup

    test "a row that changed after the drawer opened keeps the draft and offers Load latest",
         %{conn: conn, user: user, organization: organization, version: version} do
      row = save_feed_info(user, organization, version, @stored_attrs)

      {:ok, view, _html} = editor_view(conn, user, organization, version)
      open_drawer(view, "#feed-details-edit")

      # Another process updates the row after the drawer opened.
      from(f in FeedInfo, where: f.id == ^row.id)
      |> Repo.update_all(
        set: [
          feed_publisher_name: "Other Editor Name",
          updated_at: DateTime.add(row.updated_at, 60, :second)
        ]
      )

      submit_fields(view, %{"feed_publisher_name" => "Draft Partnership"})

      assert has_element?(view, "#feed-details-conflict", "Another editor changed these details")
      # A refused save is announced; the reloaded notice below is a polite status.
      assert has_element?(view, "#feed-details-conflict[role='alert']")

      assert has_element?(
               view,
               "#feed-details-conflict",
               "Nothing was saved. Your entries are kept."
             )

      assert has_element?(view, "#feed-details-load-latest", "Load latest")
      # The draft survives, the drawer stays open, and nothing was written.
      assert has_element?(view, "#feed_info_feed_publisher_name[value='Draft Partnership']")
      assert has_element?(view, "#feed-details-drawer-overlay[data-open='true']")
      assert Repo.get!(FeedInfo, row.id).feed_publisher_name == "Other Editor Name"

      view |> element("#feed-details-load-latest") |> render_click()

      assert has_element?(view, "#feed-details-conflict", "Save again to replace their changes.")
      assert has_element?(view, "#feed-details-conflict[role='status']")
      refute has_element?(view, "#feed-details-load-latest")
      assert has_element?(view, "#feed_info_feed_publisher_name[value='Draft Partnership']")
      assert Repo.get!(FeedInfo, row.id).feed_publisher_name == "Other Editor Name"

      submit_fields(view, %{"feed_publisher_name" => "Draft Partnership"})

      assert feed_info_rows(organization) == 1
      assert Repo.get!(FeedInfo, row.id).feed_publisher_name == "Draft Partnership"
      assert has_element?(view, "#feed-details-drawer-overlay[data-open='false']")
      assert has_element?(view, "#flash-info", "Feed details saved.")
    end

    test "a concurrent first save reports the same conflict without creating a second row",
         %{conn: conn, user: user, organization: organization, version: version} do
      {:ok, view, _html} = editor_view(conn, user, organization, version)
      open_drawer(view)

      # The row appears while the drawer that would create it is open.
      save_feed_info(user, organization, version, @stored_attrs)

      submit(view, %{"feed_publisher_name" => "Draft Partnership"})

      assert has_element?(view, "#feed-details-conflict")
      assert has_element?(view, "#feed_info_feed_publisher_name[value='Draft Partnership']")
      assert feed_info_rows(organization) == 1
      assert feed_info_row(organization, version).feed_publisher_name == "Metro Transit"

      view |> element("#feed-details-load-latest") |> render_click()
      submit(view, %{"feed_publisher_name" => "Draft Partnership"})

      assert feed_info_rows(organization) == 1
      assert feed_info_row(organization, version).feed_publisher_name == "Draft Partnership"
    end
  end

  describe "closed drawer" do
    setup :editor_setup

    test "Cancel closes the drawer without writing",
         %{conn: conn, user: user, organization: organization, version: version} do
      {:ok, view, _html} = editor_view(conn, user, organization, version)
      open_drawer(view)

      change(view, %{"feed_publisher_name" => "Draft Partnership"})

      view
      |> element("#feed-details-form button[phx-click='close_editor']")
      |> render_click()

      # The typed draft is the only thing standing between Cancel and the close,
      # so the question comes first and the confirmed discard writes nothing
      # (step 8).
      assert has_element?(view, "#feed-details-discard")
      view |> element("#feed-details-discard-confirm") |> render_click()

      assert has_element?(view, "#feed-details-drawer-overlay[data-open='false']")
      assert feed_info_rows(organization) == 0
      assert has_element?(view, "#feed-details-set", "Set up feed details")
    end

    test "reopening shows the stored values again",
         %{conn: conn, user: user, organization: organization, version: version} do
      save_feed_info(user, organization, version, @stored_attrs)

      {:ok, view, _html} = editor_view(conn, user, organization, version)
      open_drawer(view, "#feed-details-edit")
      change(view, %{"feed_publisher_name" => "Draft Partnership"})

      view
      |> element("#feed-details-form button[phx-click='close_editor']")
      |> render_click()

      # Discarding the draft is what returns the drawer to the stored values.
      assert has_element?(view, "#feed-details-discard")
      view |> element("#feed-details-discard-confirm") |> render_click()

      open_drawer(view, "#feed-details-edit")

      assert has_element?(view, "#feed_info_feed_publisher_name[value='Metro Transit']")
    end
  end

  describe "access and scope" do
    setup :editor_setup

    test "a membership deactivated after mount closes the drawer, flashes and writes nothing",
         %{conn: conn, user: user, organization: organization, version: version} do
      save_feed_info(user, organization, version, @stored_attrs)

      {:ok, view, _html} = editor_view(conn, user, organization, version)
      open_drawer(view, "#feed-details-edit")

      Accounts.get_user_org_membership(user.id, organization.id)
      |> deactivate_membership_fixture()

      submit_fields(view, %{"feed_publisher_name" => "Rewrite"})

      assert has_element?(view, "#feed-details-drawer-overlay[data-open='false']")

      assert has_element?(
               view,
               "#flash-error",
               "You no longer have editor access to this organization."
             )

      assert feed_info_rows(organization) == 1
      assert feed_info_row(organization, version).feed_publisher_name == "Metro Transit"
    end

    test "a deactivated membership blocks the first save and creates no row",
         %{conn: conn, user: user, organization: organization, version: version} do
      {:ok, view, _html} = editor_view(conn, user, organization, version)
      open_drawer(view)

      Accounts.get_user_org_membership(user.id, organization.id)
      |> deactivate_membership_fixture()

      submit(view, %{})

      assert has_element?(view, "#feed-details-drawer-overlay[data-open='false']")
      assert has_element?(view, "#flash-error", "no longer have editor access")
      assert feed_info_rows(organization) == 0
    end

    test "a version that is no longer published flashes and returns to Settings",
         %{conn: conn, user: user, organization: organization, version: version} do
      {:ok, view, _html} = editor_view(conn, user, organization, version)
      open_drawer(view)

      # The version stops being the organization's published version while the
      # drawer is open, which is the only way the scoped write can miss it.
      from(v in GtfsVersion, where: v.id == ^version.id)
      |> Repo.update_all(set: [publication_status: "staging", published_at: nil])

      submit(view, %{})

      assert {to_path, flash} = assert_redirect(view)
      assert to_path == settings_path(version.id)
      assert flash == %{"error" => "This version is no longer available."}
      assert feed_info_rows(organization) == 0
    end
  end
end
