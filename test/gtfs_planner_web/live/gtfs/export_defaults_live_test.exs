defmodule GtfsPlannerWeb.Gtfs.ExportDefaultsLiveTest do
  @moduledoc """
  Judges Settings › Export defaults (EV-26, AC-15, CL-17).

  The page is the organization-wide switch and realtime answer every export
  reads: the flex switch (on by default, with the reference's sentence for what
  it writes), the realtime question with its warning for a vendor's own schedule
  file, one Save, and a note naming the export defaults still to come. The cases
  read the stored row back through `ExportDefaults.get/1`, follow the switch into
  the Flex list's export-state line and a new full run's recorded value, and check
  that another organization's editor never sees or writes this organization's
  answers.
  """

  use GtfsPlannerWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Gtfs.ExportDefault
  alias GtfsPlanner.Gtfs.ExportDefaults
  alias GtfsPlanner.Gtfs.ExportRuns
  alias GtfsPlanner.Repo
  alias GtfsPlanner.Versions

  @actor %{id: Ecto.UUID.generate(), email: "exporter@example.test"}

  # The five answers `ExportDefault` stores, labelled the way the reference and
  # the service page label them.
  @realtime_options [
    {"main", "Main feed"},
    {"flex", "Flex file"},
    {"own", "Its own schedule file"},
    {"none", "No realtime"},
    {"unsure", "Not sure"}
  ]

  describe "the page" do
    setup :editor_setup

    test "reads the flex switch on and the realtime question with the stored answers", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} = live(conn, section_path(version))

      assert has_element?(view, "h1", "Export defaults")
      assert has_element?(view, "p", "All versions · Choose how future exports are written.")

      assert has_element?(
               view,
               "p",
               "Shared across all service versions for #{organization.name}."
             )

      # The switch is one labelled control, and the sentence under it is the
      # reference's account of what a full export writes.
      assert has_element?(view, "#flex-switch[checked]")
      assert has_element?(view, "label", "Include flex services in exports")

      assert has_element?(
               view,
               "label[for='realtime-source']",
               "Which file does your realtime vendor read?"
             )

      assert has_element?(
               view,
               "#flex-switch-consequence",
               "Exports also write a flex file: your fixed routes plus flex, built and published with your main feed."
             )

      # The realtime question offers every answer the schema stores, with the
      # default `:unsure` selected and its note.
      assert select_options(view, "#realtime-source") == @realtime_options

      assert has_element?(view, "#realtime-source option[value='unsure'][selected]")

      assert has_element?(
               view,
               "#realtime-note",
               "Ask your vendor. If it uses its own schedule file, apps can’t match its updates to these trips."
             )

      # One Save, and the note about the export defaults still to come.
      assert has_element?(view, "button[type='submit']", "Save changes")

      assert has_element?(
               view,
               "#export-defaults-more",
               "ID formats and stop times between timepoints will join this page."
             )

      # This page, not the Coming soon body, and it returns by the Settings link
      # the design system replaced the settings tab bar with.
      refute has_element?(view, "#coming-soon")
      assert has_element?(view, "#settings-back", "Settings")
      assert has_element?(view, "#settings-back[href='#{settings_path(version)}']")

      # Reading the page stores nothing.
      refute Repo.get_by(ExportDefault, organization_id: organization.id)
    end

    test "turning the switch off saves it, and the Flex list and the next run read it", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} = live(conn, section_path(version))

      params = %{"export_default" => %{"include_flex" => "false", "realtime_source" => "unsure"}}

      html = view |> form("#export-defaults-form", params) |> render_change()

      assert html =~ "Exports leave flex out. Riders won’t see these services in trip planners"
      refute html =~ "Export defaults saved."

      html = view |> form("#export-defaults-form", params) |> render_submit()

      assert html =~ "Export defaults saved."
      assert ExportDefaults.get(organization.id).include_flex == false

      stored = Repo.get_by(ExportDefault, organization_id: organization.id)
      assert stored.include_flex == false
      assert stored.realtime_source == :unsure

      # The Flex list's export-state line reads the same row, so it now warns.
      {:ok, list, _html} = live(conn, "/gtfs/#{version.id}/flex")
      _ = :sys.get_state(list.pid)

      assert has_element?(list, "#flex-exports", "Exports leave flex out.")
      refute has_element?(list, "#flex-exports", "Exports also write a flex file")

      # A full export run records the switch's value at creation (AC-15).
      assert {:ok, run} = ExportRuns.create_pending(organization.id, version.id, @actor, :full)
      assert run.include_flex == false
    end

    test "choosing the vendor's own schedule file saves the answer and shows its warning", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} = live(conn, section_path(version))

      params = %{"export_default" => %{"include_flex" => "true", "realtime_source" => "own"}}

      html = view |> form("#export-defaults-form", params) |> render_change()

      assert html =~
               "Apps can’t match its updates to flex trips, because the vendor’s file uses its own trip IDs."

      assert html =~ "Ask the vendor to use the trip IDs in your feeds."

      html = view |> form("#export-defaults-form", params) |> render_submit()

      assert html =~ "Export defaults saved."
      assert ExportDefaults.get(organization.id).realtime_source == :own

      # A later visit reads the stored answer back, with its note.
      {:ok, reloaded, _html} = live(conn, section_path(version))

      assert has_element?(reloaded, "#realtime-source option[value='own'][selected]")
      assert has_element?(reloaded, "#realtime-note", "uses its own trip IDs")
    end

    test "an explicit version selection keeps this page", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      {:ok, other_version} =
        Versions.create_gtfs_version(organization.id, %{name: "Second Version"})

      conn = log_in_user(conn, user, organization: organization)
      selected_version_id = to_string(other_version.id)

      {:ok, view, _html} = live(conn, section_path(version))

      render_hook(view, "switch_gtfs_version", %{"version" => selected_version_id})

      assert_push_event(view, "gtfs_version_selected", %{version_id: ^selected_version_id})
      assert_redirect(view, section_path(other_version))
    end

    test "a save rejects an answer the schema does not store and writes nothing", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} = live(conn, section_path(version))

      html =
        render_submit(view, "save", %{
          "export_default" => %{"include_flex" => "true", "realtime_source" => "bogus"}
        })

      assert html =~ "Nothing was saved. Check the highlighted field."
      assert html =~ "is invalid"
      refute Repo.get_by(ExportDefault, organization_id: organization.id)
    end
  end

  describe "placement in Settings" do
    setup :editor_setup

    test "the overview lists the built page under All versions with its own copy", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      conn = log_in_user(conn, user, organization: organization)

      {:ok, overview, _html} = live(conn, settings_path(version))
      doc = LazyHTML.from_fragment(render(overview))

      assert LazyHTML.attribute(LazyHTML.query(doc, "#settings-all-versions li"), "id") ==
               [
                 "settings-entry-garages",
                 "settings-entry-fleet",
                 "settings-entry-export_defaults",
                 "settings-entry-feed_url"
               ]

      entry = LazyHTML.query(doc, "#settings-entry-export_defaults")

      assert LazyHTML.text(LazyHTML.query(entry, "#settings-entry-export_defaults-title"))
             |> String.trim() == "Export defaults"

      assert LazyHTML.text(LazyHTML.query(entry, "a")) =~ "Export defaults"

      assert LazyHTML.attribute(LazyHTML.query(entry, "a"), "href") == [section_path(version)]

      assert LazyHTML.text(LazyHTML.query(entry, "#settings-entry-export_defaults-summary"))
             |> String.trim() == "Choose how future exports are written."

      # A built page is a working row, so it stays out of the Coming soon band.
      refute LazyHTML.text(entry) =~ "Coming soon"
      assert Enum.empty?(LazyHTML.query(entry, "#coming-soon"))

      # The section route renders the page, which returns by the Settings link.
      {:ok, view, _html} = live(conn, section_path(version))

      assert has_element?(view, "#export-defaults-form")
      refute has_element?(view, "#coming-soon")
      assert has_element?(view, "#settings-back", "Settings")
    end
  end

  describe "organization scope" do
    setup :editor_setup

    test "another organization's editor sees its own answers, and a forged id writes nothing", %{
      conn: conn,
      organization: organization
    } do
      # This organization answers "Its own schedule file" with flex off.
      {:ok, _defaults} =
        ExportDefaults.update(organization.id, %{include_flex: false, realtime_source: :own})

      other_organization = organization_fixture()
      other_user = editor_for(other_organization)
      other_version = gtfs_version_fixture(other_organization.id)

      conn = log_in_user(conn, other_user, organization: other_organization)

      {:ok, view, _html} = live(conn, section_path(other_version))

      # The second organization's page reads its own default row, not the first's.
      assert has_element?(view, "#flex-switch[checked]")
      assert has_element?(view, "#realtime-source option[value='unsure'][selected]")
      refute has_element?(view, "#realtime-source option[value='own'][selected]")

      # A hand-built submit naming the first organization writes only the second.
      html =
        render_submit(view, "save", %{
          "export_default" => %{
            "include_flex" => "true",
            "realtime_source" => "main",
            "organization_id" => organization.id
          }
        })

      assert html =~ "Export defaults saved."

      other_stored = ExportDefaults.get(other_organization.id)
      assert other_stored.include_flex == true
      assert other_stored.realtime_source == :main

      # The first organization's row is untouched, and no third row appeared.
      first = ExportDefaults.get(organization.id)
      assert first.include_flex == false
      assert first.realtime_source == :own

      assert Repo.aggregate(ExportDefault, :count) == 2
    end
  end

  # --- setup ------------------------------------------------------------------

  defp editor_setup(_context) do
    organization = organization_fixture()
    user = editor_for(organization)
    version = gtfs_version_fixture(organization.id)

    %{user: user, organization: organization, version: version}
  end

  defp editor_for(organization) do
    user = user_fixture()

    Accounts.create_user_org_membership(%{
      user_id: user.id,
      organization_id: organization.id,
      roles: ["pathways_studio_editor"]
    })

    user
  end

  # --- helpers ----------------------------------------------------------------

  defp settings_path(version), do: "/gtfs/#{version.id}/settings"

  defp section_path(version), do: "/gtfs/#{version.id}/settings/export-defaults"

  defp select_options(view, selector) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#{selector} option")
    |> Enum.map(fn option ->
      {LazyHTML.attribute(option, "value") |> List.first(),
       LazyHTML.text(option) |> String.trim()}
    end)
  end
end
