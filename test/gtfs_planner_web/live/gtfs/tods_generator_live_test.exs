defmodule GtfsPlannerWeb.Gtfs.TodsGeneratorLiveTest do
  use GtfsPlannerWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OperationsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Gtfs.Runs

  # The version-scoped route the account menu opens.
  @generator_path "/tods-generator"

  # One fixed service window every case shares: Wednesday 7 October 2026 through
  # Tuesday 20 October, weekdays only. Its first active date is 7 October, so the
  # owner's `Input.first_active_week/1` defaults the range to Monday 5 – Sunday 11
  # October and the representative week to 5 October. Those literal dates are what
  # the page must show; fixing the window is the only reason they are not relative.
  @service_start ~D[2026-10-07]
  @service_end ~D[2026-10-20]
  @first_week_start "2026-10-05"
  @first_week_end "2026-10-11"

  setup do
    organization = organization_fixture()
    user = user_fixture()

    Accounts.create_user_org_membership(%{
      user_id: user.id,
      organization_id: organization.id,
      roles: ["pathways_studio_editor"]
    })

    version = gtfs_version_fixture(organization.id)

    calendar_fixture(organization.id, version.id, %{
      service_id: "WKDY",
      start_date: @service_start,
      end_date: @service_end
    })

    %{organization: organization, user: user, version: version}
  end

  defp open_generator(conn, context) do
    conn = log_in_user(conn, context.user, organization: context.organization)
    live(conn, "/gtfs/#{context.version.id}#{@generator_path}")
  end

  defp document(html), do: LazyHTML.from_fragment(html)

  defp text_in(html, selector) do
    html |> document() |> LazyHTML.query(selector) |> LazyHTML.text()
  end

  defp selected_garage(html) do
    html |> document() |> LazyHTML.query("#tods-garage-select option[selected]")
  end

  describe "entry" do
    test "an editor opens the generator and reads its purpose before any control", context do
      {:ok, view, _html} = open_generator(context.conn, context)

      assert has_element?(view, "#tods-generator-page")
      assert has_element?(view, "#tods-generator-purpose")
      assert has_element?(view, "#tods-generator-form")

      purpose = text_in(render(view), "#tods-generator-purpose")

      # AC-2's consequences, each its own sentence: internal test data, made-up
      # assignments, the version's screens, organization-wide fictional operators,
      # preserved existing work, later exports, and no publication.
      assert purpose =~ "internal testing and demonstrations"
      assert purpose =~ "made-up operating assignments"
      assert purpose =~ "Blocks, Runs and Rosters"
      assert purpose =~ "saved for the organization"
      assert purpose =~ "Existing assignments are kept"
      assert purpose =~ "TODS exports"
      assert purpose =~ "does not publish a feed"

      # The recurring-date consequence is stated in full: a weekday slot reaches
      # matching dates outside the selected range, and differing exception dates
      # do not become staffed.
      assert purpose =~ "affects every matching date"
      assert purpose =~ "after the range you select"
      assert purpose =~ "holidays"

      scope = text_in(render(view), "#tods-generator-scope")
      assert scope =~ context.version.name
      assert scope =~ context.organization.name

      assert has_element?(view, "#tods-preview-button")
      assert String.trim(text_in(render(view), "#tods-preview-button")) == "Preview generation"
    end

    test "the range defaults to the feed's first active calendar week", context do
      {:ok, view, _html} = open_generator(context.conn, context)

      assert has_element?(view, ~s(#tods-start-date[value="#{@first_week_start}"]))
      assert has_element?(view, ~s(#tods-end-date[value="#{@first_week_end}"]))
      assert has_element?(view, ~s(#tods-representative-week[value="#{@first_week_start}"]))
    end

    test "the rules in force are the version's stored crew rules, read-only", context do
      audit = editor_audit_fixture(context.organization, context.version)

      {:ok, _settings} =
        Runs.update_crew_settings(audit, %{
          report_pull_out_minutes: 20,
          report_relief_minutes: 8,
          sign_off_minutes: 12,
          paid_break_max_minutes: 35,
          max_spread_minutes: 660
        })

      {:ok, view, _html} = open_generator(context.conn, context)

      rules = text_in(render(view), "#tods-generator-rules")

      assert rules =~ "20 min before each pull-out"
      assert rules =~ "8 min before each relief"
      assert rules =~ "35 minutes or less"
      assert rules =~ "sign-off (12 min)"

      assert text_in(render(view), "#tods-generator-rules-spread") =~ "11 h"

      assert has_element?(
               view,
               ~s(#tods-generator-rules-link[href="/gtfs/#{context.version.id}/runs"])
             )
    end
  end

  describe "garage prerequisite" do
    test "one garage is preselected, because one garage is not a choice", context do
      garage = garage_fixture(context.organization.id, %{"name" => "Depot A"})

      {:ok, view, _html} = open_generator(context.conn, context)

      assert LazyHTML.attribute(selected_garage(render(view)), "value") == [garage.id]
      refute has_element?(view, "#tods-preview-button[disabled][data-unavailable]")

      options = document(render(view)) |> LazyHTML.query("#tods-garage-select option")
      assert LazyHTML.attribute(options, "value") == ["", garage.id]
    end

    test "several garages require an explicit choice", context do
      garage_fixture(context.organization.id, %{"name" => "Depot A"})
      garage_fixture(context.organization.id, %{"name" => "Depot B"})

      {:ok, view, _html} = open_generator(context.conn, context)

      assert Enum.empty?(selected_garage(render(view)))
      assert has_element?(view, ~s(#tods-garage-select option[value=""]), "Choose a garage")
    end

    test "no garage names the prerequisite, links to Garages and blocks the preview", context do
      {:ok, view, _html} = open_generator(context.conn, context)

      assert has_element?(view, "#tods-generator-missing-garages")
      assert has_element?(view, "#tods-preview-blocked")

      assert has_element?(
               view,
               ~s(#tods-generator-missing-garages a[href="/gtfs/#{context.version.id}/settings/garages"])
             )

      # The control is disabled and reads as unavailable through the design
      # system's own mark, and the event is refused anyway: a disabled button is
      # the browser's state, never the server's authorization.
      assert has_element?(view, "#tods-preview-button[disabled][data-unavailable]")

      html =
        view
        |> form("#tods-generator-form", input: %{"start_date" => @first_week_start})
        |> render_submit()

      assert html =~ "Add a garage first"
      refute html =~ "Request ready"
    end

    test "a garage this organization does not own is not accepted as a choice", context do
      own = garage_fixture(context.organization.id, %{"name" => "Depot A"})
      other_organization = organization_fixture()
      foreign = garage_fixture(other_organization.id, %{"name" => "Foreign Depot"})

      {:ok, view, _html} = open_generator(context.conn, context)

      # The browser cannot send this value, so the event is sent directly: the
      # same shape as a garage deleted in another tab while the form was open.
      html = render_submit(view, "preview_generation", %{"input" => %{"garage_id" => foreign.id}})

      assert Enum.empty?(selected_garage(html))
      refute html =~ foreign.id
      refute html =~ "Foreign Depot"
      assert text_in(html, "#tods-generator-form-error") =~ "Fallback garage"

      # The organization's own garage is still the only garage the control offers.
      options = html |> document() |> LazyHTML.query("#tods-garage-select option")
      assert LazyHTML.attribute(options, "value") == ["", own.id]
    end
  end

  describe "request validation" do
    test "a submit without a chosen garage reveals the field error and keeps the dates",
         context do
      garage_fixture(context.organization.id, %{"name" => "Depot A"})
      garage_fixture(context.organization.id, %{"name" => "Depot B"})

      {:ok, view, _html} = open_generator(context.conn, context)

      html =
        view
        |> form("#tods-generator-form",
          input: %{"start_date" => "2026-10-12", "end_date" => "2026-10-18"}
        )
        |> render_submit()

      assert has_element?(view, "#tods-generator-form-error")
      assert text_in(html, "#tods-generator-form-error") =~ "Fallback garage"
      assert Enum.empty?(selected_garage(html))

      # The submitted drafts stay on the form, and the primary control is not
      # disabled for an invalid value: submitting is how the errors appear.
      assert has_element?(view, ~s(#tods-start-date[value="2026-10-12"]))
      assert has_element?(view, ~s(#tods-end-date[value="2026-10-18"]))
      refute has_element?(view, "#tods-preview-button[disabled]")
      refute render(view) =~ "Request ready"
    end

    test "an end date before the start date is revealed on the end date", context do
      garage = garage_fixture(context.organization.id, %{"name" => "Depot A"})

      {:ok, view, _html} = open_generator(context.conn, context)

      html =
        view
        |> form("#tods-generator-form",
          input: %{
            "start_date" => "2026-10-18",
            "end_date" => "2026-10-12",
            "garage_id" => garage.id
          }
        )
        |> render_submit()

      assert text_in(html, "#tods-generator-form-error") =~ "Last date"
      assert has_element?(view, ~s(#tods-end-date[value="2026-10-12"]))
      refute render(view) =~ "Request ready"
    end

    test "a representative week that is not a Monday is revealed", context do
      garage = garage_fixture(context.organization.id, %{"name" => "Depot A"})

      {:ok, view, _html} = open_generator(context.conn, context)

      html =
        view
        |> form("#tods-generator-form",
          input: %{
            "start_date" => @first_week_start,
            "end_date" => @first_week_end,
            "representative_week" => "2026-10-06",
            "garage_id" => garage.id
          }
        )
        |> render_submit()

      assert text_in(html, "#tods-generator-form-error") =~ "Representative week"
      refute html =~ "Request ready"
    end

    test "a valid request is named back with the values it would use", context do
      garage = garage_fixture(context.organization.id, %{"name" => "Depot A"})
      garage_fixture(context.organization.id, %{"name" => "Depot B"})

      {:ok, view, _html} = open_generator(context.conn, context)

      html =
        view
        |> form("#tods-generator-form",
          input: %{
            "start_date" => "2026-10-12",
            "end_date" => "2026-10-25",
            "representative_week" => "2026-10-19",
            "garage_id" => garage.id,
            "terminal_relief?" => "true"
          }
        )
        |> render_submit()

      status = text_in(html, "#tods-generator-status")

      assert status =~ "Dates Oct 12, 2026 to Oct 25, 2026"
      assert status =~ "representative week Oct 19, 2026"
      assert status =~ "fallback garage Depot A"
      assert status =~ "terminal relief on"
      assert has_element?(view, "#tods-terminal-relief[checked]")
    end
  end

  describe "access" do
    test "a member without the editor role is refused on the direct route", context do
      member = user_fixture()
      conn = log_in_user(context.conn, member, organization: context.organization)

      assert {:error, {:redirect, %{to: "/admin/organizations", flash: %{"error" => flash}}}} =
               live(conn, "/gtfs/#{context.version.id}#{@generator_path}")

      assert flash =~ "not authorized"
    end

    test "another organization's version is not a trusted assign", context do
      other_organization = organization_fixture()
      other_version = gtfs_version_fixture(other_organization.id, %{name: "Other Org Version"})

      conn = log_in_user(context.conn, context.user, organization: context.organization)

      assert {:error, {:redirect, %{to: "/"}}} =
               live(conn, "/gtfs/#{other_version.id}#{@generator_path}")
    end
  end
end
