defmodule GtfsPlannerWeb.Gtfs.FeedDetailsDraftsLiveTest do
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

  @url_message "Enter a full web address, starting with https:// or http://."

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

  # The same nine fields as the browser would send them back on `phx-change`,
  # with every value equal to the stored row.
  @stored_params %{
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

  defp editor_view(conn, user, organization, version) do
    conn = log_in_user(conn, user, organization: organization)
    live(conn, feed_details_path(version.id))
  end

  # The row is written by the application's own writer, so every case starts from
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

  # One keystroke as the browser sends it: the field names are the form's own
  # inputs, because `form/2` refuses a key the form does not render.
  defp change(view, attrs) do
    view |> form("#feed-details-form", feed_info: attrs) |> render_change()
  end

  defp close_from_form(view) do
    view |> element("#feed-details-form button[phx-click='close_editor']") |> render_click()
  end

  defp dirty?(view), do: has_element?(view, "#feed-details-unsaved-guard[data-dirty='true']")

  defp assert_clean(view) do
    refute has_element?(view, "#feed-details-unsaved")
    assert has_element?(view, "#feed-details-unsaved-guard[data-dirty='false']")
  end

  describe "clean draft" do
    setup :editor_setup

    test "a drawer closed without a change closes and asks nothing",
         %{conn: conn, user: user, organization: organization, version: version} do
      save_feed_info(user, organization, version, @stored_attrs)

      {:ok, view, _html} = editor_view(conn, user, organization, version)
      open_drawer(view, "#feed-details-edit")

      assert_clean(view)
      refute has_element?(view, "#feed-details-discard")

      view |> element("#feed-details-drawer-close") |> render_click()

      assert has_element?(view, "#feed-details-drawer-overlay[data-open='false']")
      refute has_element?(view, "#feed-details-discard")
      assert feed_info_rows(organization) == 1
    end

    test "a round trip that changes nothing is not a draft",
         %{conn: conn, user: user, organization: organization, version: version} do
      save_feed_info(user, organization, version, @stored_attrs)

      {:ok, view, _html} = editor_view(conn, user, organization, version)
      open_drawer(view, "#feed-details-edit")

      # The client repeats every field on every keystroke, so a form that only
      # echoes the stored row must stay clean.
      change(view, @stored_params)

      assert_clean(view)

      # The client also marks an input the editor has not focused with
      # `_unused_<field>`, a key the form does not render; it is sent through the
      # event itself, the way `feed_details_editor_live_test.exs` does it, and it
      # must not turn an unchanged form into a draft.
      render_change(view, "validate", %{
        "feed_info" => Map.put(@stored_params, "_unused_feed_publisher_name", "")
      })

      assert_clean(view)

      view |> element("#feed-details-drawer-close") |> render_click()

      assert has_element?(view, "#feed-details-drawer-overlay[data-open='false']")
      refute has_element?(view, "#feed-details-discard")
    end

    test "a stored value outside the editor rules is not a draft until it is touched",
         %{conn: conn, user: user, organization: organization, version: version} do
      imported = Map.put(@stored_attrs, :feed_publisher_url, "www.example.com")
      import_feed_info(organization, version, imported)

      {:ok, view, _html} = editor_view(conn, user, organization, version)
      open_drawer(view, "#feed-details-edit")

      change(view, Map.put(@stored_params, "feed_publisher_url", "www.example.com"))

      # Untouched, the imported value is not a change, so closing is a plain
      # close even though the editor changeset would refuse that URL. The guard
      # measures the draft, not the row's imported shape.
      assert_clean(view)

      view |> element("#feed-details-drawer-close") |> render_click()

      assert has_element?(view, "#feed-details-drawer-overlay[data-open='false']")
      refute has_element?(view, "#feed-details-discard")
      assert feed_info_row(organization, version).feed_publisher_url == "www.example.com"
    end

    test "the dismiss control every close route clicks is the asking handler",
         %{conn: conn, user: user, organization: organization, version: version} do
      save_feed_info(user, organization, version, @stored_attrs)

      {:ok, view, _html} = editor_view(conn, user, organization, version)
      open_drawer(view, "#feed-details-edit")
      change(view, Map.put(@stored_params, "feed_publisher_name", "Draft Partnership"))

      # Escape and the backdrop reach the drawer through the `OverlayDialog`
      # hook, which clicks this element's dismiss control; Cancel sends the same
      # event. All three therefore land on the asking handler (AC-6).
      assert has_element?(
               view,
               "#feed-details-drawer-close[data-dialog-dismiss][phx-click='close_editor']"
             )

      assert has_element?(
               view,
               "#feed-details-form button[phx-click='close_editor']",
               "Cancel"
             )

      view |> element("#feed-details-drawer-close") |> render_click()

      assert has_element?(view, "#feed-details-discard")
    end
  end

  describe "changed draft" do
    setup :editor_setup

    test "a changed publisher name shows the label and arms the guard",
         %{conn: conn, user: user, organization: organization, version: version} do
      save_feed_info(user, organization, version, @stored_attrs)

      {:ok, view, _html} = editor_view(conn, user, organization, version)
      open_drawer(view, "#feed-details-edit")

      change(view, Map.put(@stored_params, "feed_publisher_name", "Metro Transit (draft)"))

      assert has_element?(view, "#feed-details-unsaved", "Unsaved changes")
      assert dirty?(view)

      # The guard is the shared hidden hook element with a stable DOM id, and it
      # is invisible: the state the editor reads is the badge in the header.
      # LiveView resolves the source's `.UnsavedChangesGuard` to the module that
      # declares the colocated hook, so that resolved name is the contract a
      # browser and this test both see (step 17/18/21 reuse the same component).
      assert has_element?(
               view,
               "#feed-details-unsaved-guard" <>
                 "[phx-hook='GtfsPlannerWeb.Gtfs.FeedSettingsComponents.UnsavedChangesGuard']" <>
                 "[data-dirty='true'][hidden]"
             )

      # Re-typing the stored value again is not a draft any more.
      change(view, Map.put(@stored_params, "feed_publisher_name", "Metro Transit"))

      assert_clean(view)
    end

    test "a whitespace-only edit is not a change",
         %{conn: conn, user: user, organization: organization, version: version} do
      save_feed_info(user, organization, version, @stored_attrs)

      {:ok, view, _html} = editor_view(conn, user, organization, version)
      open_drawer(view, "#feed-details-edit")

      change(view, Map.put(@stored_params, "feed_publisher_name", "  Metro Transit  "))

      assert_clean(view)

      view |> element("#feed-details-drawer-close") |> render_click()

      assert has_element?(view, "#feed-details-drawer-overlay[data-open='false']")
      refute has_element?(view, "#feed-details-discard")
    end

    test "an invalid draft is still a draft",
         %{conn: conn, user: user, organization: organization, version: version} do
      save_feed_info(user, organization, version, @stored_attrs)

      {:ok, view, _html} = editor_view(conn, user, organization, version)
      open_drawer(view, "#feed-details-edit")

      change(view, Map.put(@stored_params, "feed_publisher_url", "www.example.com"))

      assert has_element?(view, "#feed_info_feed_publisher_url-error", @url_message)
      assert dirty?(view)

      close_from_form(view)

      assert has_element?(view, "#feed-details-discard")
      view |> element("#feed-details-discard-confirm") |> render_click()

      assert feed_info_row(organization, version).feed_publisher_url == "https://metro.example"
    end

    test "closing a changed draft asks to discard and Keep editing keeps it",
         %{conn: conn, user: user, organization: organization, version: version} do
      save_feed_info(user, organization, version, @stored_attrs)

      {:ok, view, _html} = editor_view(conn, user, organization, version)
      open_drawer(view, "#feed-details-edit")
      change(view, Map.put(@stored_params, "feed_publisher_name", "Draft Partnership"))

      close_from_form(view)

      assert has_element?(view, "#feed-details-discard[role='alertdialog']")
      assert has_element?(view, "#feed-details-discard-title", "Discard unsaved changes?")

      assert has_element?(
               view,
               "#feed-details-discard-body",
               "Your edits will be lost. The saved details stay unchanged."
             )

      assert has_element?(view, "#feed-details-discard-cancel", "Keep editing")
      assert has_element?(view, "#feed-details-discard-confirm", "Discard changes")

      assert has_element?(
               view,
               "#feed-details-discard[aria-describedby='feed-details-discard-body']"
             )

      # The drawer stays up behind the question, with the draft still in it.
      assert has_element?(view, "#feed-details-drawer-overlay[data-open='true']")
      assert has_element?(view, "#feed_info_feed_publisher_name[value='Draft Partnership']")

      view |> element("#feed-details-discard-cancel") |> render_click()

      refute has_element?(view, "#feed-details-discard")
      assert has_element?(view, "#feed_info_feed_publisher_name[value='Draft Partnership']")
      assert dirty?(view)
      assert feed_info_rows(organization) == 1

      # Keeping the draft means keeping the question: the next close asks again.
      close_from_form(view)

      assert has_element?(view, "#feed-details-discard")
    end

    test "Discard changes closes the drawer and leaves the stored row unchanged",
         %{conn: conn, user: user, organization: organization, version: version} do
      row = save_feed_info(user, organization, version, @stored_attrs)

      {:ok, view, _html} = editor_view(conn, user, organization, version)
      open_drawer(view, "#feed-details-edit")

      change(view, %{
        "feed_publisher_name" => "Draft Partnership",
        "feed_contact_email" => "draft@example.test"
      })

      view |> element("#feed-details-drawer-close") |> render_click()
      view |> element("#feed-details-discard-confirm") |> render_click()

      assert has_element?(view, "#feed-details-drawer-overlay[data-open='false']")
      refute has_element?(view, "#feed-details-discard")
      assert_clean(view)

      stored = Repo.get!(FeedInfo, row.id)
      assert stored.feed_publisher_name == "Metro Transit"
      assert stored.feed_contact_email == "data@metro.example"
      assert feed_info_rows(organization) == 1

      # The discarded draft is gone: reopening shows the stored values.
      open_drawer(view, "#feed-details-edit")

      assert has_element?(view, "#feed_info_feed_publisher_name[value='Metro Transit']")
      refute has_element?(view, "#feed-details-unsaved")
    end

    test "Discard changes on a new draft creates no row",
         %{conn: conn, user: user, organization: organization, version: version} do
      {:ok, view, _html} = editor_view(conn, user, organization, version)
      open_drawer(view)

      change(view, %{
        "feed_publisher_name" => "Draft Partnership",
        "feed_publisher_url" => "https://draft.example",
        "feed_lang" => "en"
      })

      assert has_element?(view, "#feed-details-unsaved")
      view |> element("#feed-details-drawer-close") |> render_click()
      view |> element("#feed-details-discard-confirm") |> render_click()

      assert has_element?(view, "#feed-details-drawer-overlay[data-open='false']")
      assert feed_info_rows(organization) == 0
      assert has_element?(view, "#feed-details-set", "Set up feed details")
    end
  end

  describe "after a save or a conflict" do
    setup :editor_setup

    test "a successful save closes without a question and leaves the guard clean",
         %{conn: conn, user: user, organization: organization, version: version} do
      {:ok, view, _html} = editor_view(conn, user, organization, version)
      open_drawer(view)

      params = Map.merge(@stored_params, %{"feed_start_date" => "", "feed_end_date" => ""})

      view |> form("#feed-details-form", feed_info: params) |> render_change()

      assert dirty?(view)

      view |> form("#feed-details-form", feed_info: params) |> render_submit()

      assert has_element?(view, "#feed-details-drawer-overlay[data-open='false']")
      refute has_element?(view, "#feed-details-discard")
      assert_clean(view)
      assert feed_info_rows(organization) == 1
    end

    test "a conflict keeps the draft and closing still asks",
         %{conn: conn, user: user, organization: organization, version: version} do
      row = save_feed_info(user, organization, version, @stored_attrs)

      {:ok, view, _html} = editor_view(conn, user, organization, version)
      open_drawer(view, "#feed-details-edit")

      from(f in FeedInfo, where: f.id == ^row.id)
      |> Repo.update_all(
        set: [
          feed_publisher_name: "Other Editor Name",
          updated_at: DateTime.add(row.updated_at, 60, :second)
        ]
      )

      submit = Map.put(@stored_params, "feed_publisher_name", "Draft Partnership")
      view |> form("#feed-details-form", feed_info: submit) |> render_submit()

      assert has_element?(view, "#feed-details-conflict")
      assert dirty?(view)

      # The conflict callout is reloaded rather than discarded: ``Load latest``
      # keeps the draft, so the drawer is still changed and still asks.
      view |> element("#feed-details-load-latest") |> render_click()

      assert has_element?(view, "#feed_info_feed_publisher_name[value='Draft Partnership']")
      assert dirty?(view)

      close_from_form(view)

      assert has_element?(view, "#feed-details-discard")
      view |> element("#feed-details-discard-confirm") |> render_click()

      assert Repo.get!(FeedInfo, row.id).feed_publisher_name == "Other Editor Name"
    end
  end

  describe "use date label" do
    setup :editor_setup

    test "filling the label the row already stores is not a draft",
         %{conn: conn, user: user, organization: organization, version: version} do
      today = Date.to_iso8601(DisplayClock.today(organization.id, version.id).date)
      save_feed_info(user, organization, version, Map.put(@stored_attrs, :feed_version, today))

      {:ok, view, _html} = editor_view(conn, user, organization, version)
      open_drawer(view, "#feed-details-edit")

      assert has_element?(view, "#feed_info_feed_version[value='#{today}']")

      view |> element("#feed-details-use-date-label") |> render_click()

      assert_clean(view)

      view |> element("#feed-details-drawer-close") |> render_click()

      assert has_element?(view, "#feed-details-drawer-overlay[data-open='false']")
      refute has_element?(view, "#feed-details-discard")
    end

    test "filling a different label is a draft",
         %{conn: conn, user: user, organization: organization, version: version} do
      save_feed_info(user, organization, version, @stored_attrs)

      {:ok, view, _html} = editor_view(conn, user, organization, version)
      open_drawer(view, "#feed-details-edit")

      view |> element("#feed-details-use-date-label") |> render_click()

      assert has_element?(view, "#feed-details-unsaved")
      assert dirty?(view)
    end
  end
end
