defmodule GtfsPlannerWeb.Gtfs.AgencyEditLiveTest do
  @moduledoc """
  The edit agency drawer on the Agencies page: the row a name opens, the save,
  the imported language it keeps, the conflict another editor causes, the tenant
  and membership refusals and the discard question (AC-15, AC-16, AC-28; CL-16,
  EV-22).

  Every case drives the page through the real router and the real context
  functions the LiveView calls, so a case that passes here went through
  `FeedSettings.get_agency/3` and `change_agency/2`, and its save through
  `FeedSettings.update_agency/4` with the LiveView's own audit context. What a
  save stores is read back through the scoped context read, so "no write" and
  "which values" are only claimed from the stored row, and the one concurrency
  case moves the row the way another editor's save would: the drawer's token is
  the `updated_at` it loaded, held in the socket and never in the form (CR-9).
  """

  use GtfsPlannerWeb.ConnCase, async: true

  import Ecto.Query
  import Phoenix.LiveViewTest
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.Agency
  alias GtfsPlanner.Repo

  @open_drawer "#agency-drawer-overlay[data-open='true']"
  @closed_drawer "#agency-drawer-overlay[data-open='false']"
  @editor_access "You no longer have editor access to this organization."
  @missing_agency "This agency no longer exists."
  @zone_callout "Schedule timezone for this version. To update every agency together, use Change timezone on the agency list."
  @identity "Agency ID HBR · Preserved in imports and exports"

  defp agencies_path(version_id), do: "/gtfs/#{version_id}/settings/agencies"

  # A per-call address: the shared `user_fixture/1` counter restarts with each
  # BEAM run, so a row an unboxed test left in the shared database can collide
  # with it inside the fixture. The prefix keeps this file out of that range.
  defp editor_email do
    "agencies-edit-#{System.pid()}-#{System.unique_integer([:positive])}@example.com"
  end

  defp editor_setup(_context) do
    organization = organization_fixture()
    user = user_fixture(%{email: editor_email()})

    Accounts.create_user_org_membership(%{
      user_id: user.id,
      organization_id: organization.id,
      roles: ["pathways_studio_editor"]
    })

    version = gtfs_version_fixture(organization.id)

    %{user: user, organization: organization, version: version}
  end

  # Rows are built through the context create the application writes with, so
  # nothing a changeset refuses can hide inside a fixture. An imported row is an
  # ordinary stored row: the drawer's own read is what has to cope with it.
  defp create_agency(organization, version, attrs \\ %{}) do
    {:ok, agency} =
      Gtfs.create_agency(
        Map.merge(
          %{
            organization_id: organization.id,
            gtfs_version_id: version.id,
            agency_id: "HBR",
            agency_name: "Harbor Shuttle",
            agency_url: "https://harbor.example",
            agency_timezone: "America/New_York"
          },
          attrs
        )
      )

    agency
  end

  # The row as stored, read through the scoped context read the page lists with,
  # so an expectation reads the same fields the drawer wrote.
  defp stored_agency(organization, version, agency_id) do
    organization.id
    |> Gtfs.list_agencies(version.id)
    |> Enum.find(&(&1.agency_id == agency_id))
  end

  defp open_edit(view, agency), do: view |> element("#agency-open-#{agency.id}") |> render_click()

  defp edit_form(view, params), do: form(view, "#agency-form", %{"agency" => params})

  defp submit_edit(view, params), do: view |> edit_form(params) |> render_submit()

  defp change_edit(view, params), do: view |> edit_form(params) |> render_change()

  defp text_of(doc, selector) do
    doc
    |> LazyHTML.query(selector)
    |> LazyHTML.text()
    # The template wraps long copy across source lines, so the rendered text
    # carries that indentation: compare readings, not source formatting.
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  # Every visible field label in the form, in the order the drawer renders them.
  defp field_labels(doc) do
    doc
    |> LazyHTML.query("#agency-form label .label")
    |> Enum.map(&(&1 |> LazyHTML.text() |> String.replace(~r/\s+/, " ") |> String.trim()))
  end

  # The selected option of a select, as `{label, value}`, read from the rendered
  # markup: the group an option sits in is what tells "the list offers this code"
  # apart from "the row stores a code the list does not offer".
  defp selected_option(doc, selector) do
    doc
    |> LazyHTML.query("#{selector} option[selected]")
    |> Enum.map(fn option ->
      {option |> LazyHTML.text() |> String.trim(), LazyHTML.attribute(option, "value")}
    end)
  end

  defp option_group_labels(doc, selector) do
    doc
    |> LazyHTML.query("#{selector} optgroup")
    |> Enum.flat_map(&LazyHTML.attribute(&1, "label"))
  end

  # Every `name` the form submits. The drawer's scope fields are asserted absent
  # this way rather than by a selector: the name the browser posts is what would
  # move a row, and a selector would only prove the markup spelling.
  defp input_names(doc) do
    doc |> LazyHTML.query("#agency-form input") |> Enum.flat_map(&LazyHTML.attribute(&1, "name"))
  end

  describe "opening the edit drawer" do
    setup :editor_setup

    test "a name opens the row it names with a read-only ID and the version zone", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      conn = log_in_user(conn, user, organization: organization)
      agency = create_agency(organization, version)

      {:ok, view, _html} = live(conn, agencies_path(version.id))

      # The summary's Edit details is the button that opens the row, and the
      # button is named for the row it opens rather than for its position.
      assert has_element?(view, "#agency-open-#{agency.id}", "Edit details")
      assert has_element?(view, "#agency-summary-name", "Harbor Shuttle")
      refute has_element?(view, @open_drawer)
      refute has_element?(view, "#agency-form")

      open_edit(view, agency)

      assert has_element?(view, @open_drawer)
      assert has_element?(view, "#agency-drawer-title", "Harbor Shuttle")
      assert has_element?(view, "#agency-drawer-scope", "#{version.name} · #{organization.name}")

      doc = LazyHTML.from_fragment(render(view))

      # The prototype's identity box: the ID is a fact about the row, and the
      # form submits no field that could move the row's tenant or version (R1).
      assert text_of(doc, "#agency-identity") == @identity
      refute has_element?(view, "#agency-form_agency_id")
      refute "agency[agency_id]" in input_names(doc)
      refute "agency[organization_id]" in input_names(doc)
      refute "agency[gtfs_version_id]" in input_names(doc)
      refute "agency[agency_timezone]" in input_names(doc)

      # The version holds one zone, so the edit form names it rather than
      # offering a second one: changing a zone is the timezone flow's job
      # (R2, AC-15).
      refute has_element?(view, "#agency-form_agency_timezone")
      refute has_element?(view, "#agency-form_agency_timezone-zones")
      assert text_of(doc, "#agency-zone-callout") =~ "America/New_York"
      assert text_of(doc, "#agency-zone-callout") =~ @zone_callout

      assert field_labels(doc) == [
               "Agency name",
               "Website",
               "Language (optional)",
               "Phone (optional)",
               "Email (optional)",
               "Fare website (optional)"
             ]

      # The stored values are the form's starting values, and the footer is the
      # edit drawer's own: Cancel and Save changes.
      assert has_element?(view, "#agency-form_agency_name[value='Harbor Shuttle']")
      assert has_element?(view, "#agency-form_agency_url[value='https://harbor.example']")
      assert has_element?(view, "#agency-cancel", "Cancel")
      assert has_element?(view, "#agency-save", "Save changes")
      assert has_element?(view, "#agency-unsaved-guard[data-dirty='false']")
      refute has_element?(view, "#agency-unsaved")
      refute has_element?(view, "#agency-conflict")
    end
  end

  describe "saving an edit" do
    setup :editor_setup

    test "a changed phone is stored exactly and flashes", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      conn = log_in_user(conn, user, organization: organization)
      agency = create_agency(organization, version)

      {:ok, view, _html} = live(conn, agencies_path(version.id))
      open_edit(view, agency)

      submit_edit(view, %{"agency_phone" => "(212) 555-RIDE"})

      assert has_element?(view, @closed_drawer)
      assert has_element?(view, "#flash-info", "Changes saved.")

      stored = stored_agency(organization, version, "HBR")

      # The phone is kept exactly as entered, including its punctuation, and
      # nothing else moved: the ID, the scope and the zone stay the row's own.
      assert stored.agency_phone == "(212) 555-RIDE"
      assert stored.agency_id == "HBR"
      assert stored.agency_name == "Harbor Shuttle"
      assert stored.agency_url == "https://harbor.example"
      assert stored.agency_timezone == "America/New_York"

      # The summary behind the drawer shows the same row with the saved phone,
      # and reopening reads the saved value back.
      assert has_element?(view, "#agency-summary-name", "Harbor Shuttle")
      assert has_element?(view, "#agency-summary-phone", "(212) 555-RIDE")

      open_edit(view, stored)

      assert has_element?(view, "#agency-form_agency_phone[value='(212) 555-RIDE']")
    end

    test "a stored language the list does not offer stays selected and survives an unrelated save",
         %{conn: conn, user: user, organization: organization, version: version} do
      conn = log_in_user(conn, user, organization: organization)
      agency = create_agency(organization, version, %{agency_lang: "en-US"})

      {:ok, view, _html} = live(conn, agencies_path(version.id))
      open_edit(view, agency)

      doc = LazyHTML.from_fragment(render(view))

      # `en-US` is not an ISO 639-1 code, so the imported value is neither
      # replaced nor invisible: it is the select's own "Current value" entry and
      # the selected option.
      assert "Current value" in option_group_labels(doc, "#agency-form_agency_lang")
      assert selected_option(doc, "#agency-form_agency_lang") == [{"en-US", ["en-US"]}]

      submit_edit(view, %{"agency_phone" => "(212) 555-RIDE"})

      assert has_element?(view, "#flash-info", "Changes saved.")

      stored = stored_agency(organization, version, "HBR")

      # The save changed the phone and left the code the editor never touched,
      # because only changed fields are validated or written (R9, R12).
      assert stored.agency_lang == "en-US"
      assert stored.agency_phone == "(212) 555-RIDE"
    end
  end

  describe "a concurrent edit" do
    setup :editor_setup

    test "a save on a moved row keeps the draft, and Load latest lets it save again", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      conn = log_in_user(conn, user, organization: organization)
      agency = create_agency(organization, version)

      {:ok, view, _html} = live(conn, agencies_path(version.id))
      open_edit(view, agency)
      change_edit(view, %{"agency_phone" => "(212) 555-RIDE"})

      # Another editor's save moves the row after this drawer loaded it.
      from(a in Agency, where: a.id == ^agency.id)
      |> Repo.update_all(
        set: [
          agency_name: "Harbor Shuttle Group",
          updated_at: DateTime.add(agency.updated_at, 60, :second)
        ]
      )

      submit_edit(view, %{"agency_phone" => "(212) 555-RIDE"})

      # Nothing is overwritten, the drawer stays open and the entries are kept.
      assert has_element?(view, @open_drawer)
      assert has_element?(view, "#agency-conflict", "Another editor changed this agency")
      assert has_element?(view, "#agency-conflict", "Nothing was saved. Your entries are kept.")
      assert has_element?(view, "#agency-load-latest", "Load latest")
      assert has_element?(view, "#agency-form_agency_phone[value='(212) 555-RIDE']")
      assert has_element?(view, "#agency-unsaved", "Unsaved changes")
      refute has_element?(view, "#flash-info")

      assert stored_agency(organization, version, "HBR").agency_name == "Harbor Shuttle Group"

      view |> element("#agency-load-latest") |> render_click()

      # The latest row and its token are loaded, the draft is untouched, and the
      # next save replaces what the other editor stored.
      assert has_element?(view, "#agency-conflict", "Latest agency loaded")
      assert has_element?(view, "#agency-conflict", "Save again to replace their changes.")
      refute has_element?(view, "#agency-load-latest")
      assert has_element?(view, "#agency-form_agency_phone[value='(212) 555-RIDE']")
      assert stored_agency(organization, version, "HBR").agency_name == "Harbor Shuttle Group"

      submit_edit(view, %{"agency_phone" => "(212) 555-RIDE"})

      assert has_element?(view, @closed_drawer)
      assert has_element?(view, "#flash-info", "Changes saved.")

      stored = stored_agency(organization, version, "HBR")

      assert stored.agency_phone == "(212) 555-RIDE"
      assert stored.agency_name == "Harbor Shuttle"
    end
  end

  describe "access" do
    setup :editor_setup

    test "another organization's agency UUID opens nothing and is reported as gone", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      conn = log_in_user(conn, user, organization: organization)
      create_agency(organization, version)

      foreign_organization = organization_fixture()
      foreign_version = gtfs_version_fixture(foreign_organization.id)
      foreign_agency = create_agency(foreign_organization, foreign_version)

      {:ok, view, _html} = live(conn, agencies_path(version.id))

      # The scoped read is the page's own (CR-1), so a row of another tenant is
      # not a row this drawer can show or write.
      render_click(view, "open_edit", %{
        "id" => foreign_agency.id,
        "opener_id" => "agency-open-#{foreign_agency.id}"
      })

      assert has_element?(view, "#flash-error", @missing_agency)
      assert has_element?(view, @closed_drawer)
      refute has_element?(view, "#agency-form")
      refute has_element?(view, "#agency-identity")

      # The foreign row is untouched, and so is this version's own row.
      assert Repo.get!(Agency, foreign_agency.id).agency_name == "Harbor Shuttle"

      render_click(view, "open_edit", %{"id" => "not-a-uuid"})

      assert has_element?(view, "#flash-error", @missing_agency)
      assert has_element?(view, @closed_drawer)
    end

    test "a membership demoted after the drawer opened refuses the save", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      conn = log_in_user(conn, user, organization: organization)
      agency = create_agency(organization, version)

      {:ok, view, _html} = live(conn, agencies_path(version.id))
      open_edit(view, agency)
      change_edit(view, %{"agency_phone" => "(212) 555-RIDE"})

      Accounts.get_user_org_membership(user.id, organization.id)
      |> deactivate_membership_fixture()

      submit_edit(view, %{"agency_phone" => "(212) 555-RIDE"})

      assert has_element?(view, @closed_drawer)
      assert has_element?(view, "#flash-error", @editor_access)
      assert stored_agency(organization, version, "HBR").agency_phone == nil
    end
  end

  describe "an unsaved draft" do
    setup :editor_setup

    test "closing a changed form asks before discarding, and Discard writes nothing", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      conn = log_in_user(conn, user, organization: organization)
      agency = create_agency(organization, version)

      {:ok, view, _html} = live(conn, agencies_path(version.id))

      # An untouched form closes without a question.
      open_edit(view, agency)
      view |> element("#agency-drawer-close") |> render_click()

      assert has_element?(view, @closed_drawer)
      refute has_element?(view, "#agency-discard")

      open_edit(view, agency)
      change_edit(view, %{"agency_phone" => "(212) 555-RIDE"})

      assert has_element?(view, "#agency-unsaved", "Unsaved changes")
      assert has_element?(view, "#agency-unsaved-guard[data-dirty='true']")

      # Cancel asks, and the close button is the same asking handler the
      # `OverlayDialog` hook clicks for Escape and the backdrop.
      view |> element("#agency-cancel") |> render_click()

      assert has_element?(view, "#agency-discard[role='alertdialog']")
      assert has_element?(view, "#agency-discard-title", "Discard unsaved changes?")
      assert has_element?(view, "#agency-discard-body", "Your entries will be lost.")
      assert has_element?(view, "#agency-discard-body", "The stored agency stays unchanged.")
      assert has_element?(view, "#agency-discard-confirm", "Discard changes")
      assert has_element?(view, "#agency-discard-cancel", "Keep editing")

      # Keep editing keeps both the drawer and the entries.
      view |> element("#agency-discard-cancel") |> render_click()

      refute has_element?(view, "#agency-discard")
      assert has_element?(view, @open_drawer)
      assert has_element?(view, "#agency-form_agency_phone[value='(212) 555-RIDE']")

      # Discard closes the drawer and stores nothing.
      view |> element("#agency-drawer-close") |> render_click()
      view |> element("#agency-discard-confirm") |> render_click()

      assert has_element?(view, @closed_drawer)
      refute has_element?(view, "#agency-discard")
      assert stored_agency(organization, version, "HBR").agency_phone == nil

      # The discarded draft is gone: reopening shows the stored row, whose empty
      # phone renders no value attribute at all.
      open_edit(view, agency)

      assert LazyHTML.attribute(
               LazyHTML.query(LazyHTML.from_fragment(render(view)), "#agency-form_agency_phone"),
               "value"
             ) == []

      assert has_element?(view, "#agency-unsaved-guard[data-dirty='false']")
      refute has_element?(view, "#agency-unsaved")
    end
  end
end
