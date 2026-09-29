defmodule GtfsPlannerWeb.Home.SharedComponentsTest do
  @moduledoc """
  The shared homepage regions, rendered in isolation.

  The components never load: every case passes the two shapes the page owns —
  a described resume item (`GtfsPlanner.Gtfs.RecentChanges.Describe`) and the
  check-and-share facts (`GtfsPlanner.Home.check_and_share/3`) — so these cases
  pin the reference's copy, tones, links and states without a database.
  """

  use ExUnit.Case, async: true

  import Phoenix.Component, only: [sigil_H: 2]
  import Phoenix.LiveViewTest

  alias GtfsPlanner.Organizations.Organization
  alias GtfsPlannerWeb.Home.SharedComponents

  @version_id "11111111-1111-1111-1111-111111111111"
  @check_run_id "33333333-3333-3333-3333-333333333333"
  @export_run_id "44444444-4444-4444-4444-444444444444"
  @route %{
    route_id: "12",
    route_short_name: "12",
    route_color: "1B67B2",
    route_text_color: "FFFFFF"
  }

  defp planner_org,
    do: %Organization{id: "22222222-2222-2222-2222-222222222222", product: :planner}

  defp pathways_org,
    do: %Organization{id: "22222222-2222-2222-2222-222222222222", product: :pathways}

  defp item(overrides \\ %{}) do
    Map.merge(
      %{
        kind: :calendar,
        title: "Weekday",
        context: "Calendar · Sep 27, 2:18 PM",
        detail: "end date moved to Dec 31",
        route: nil,
        params: %{service_id: "WKDY"},
        actor_email: "lee@northcoast.example",
        local_at: ~N[2026-09-27 14:18:00],
        same_day_count: 1
      },
      overrides
    )
  end

  defp schedules_item(overrides \\ %{}) do
    item(
      Map.merge(
        %{
          kind: :schedules,
          title: "Downtown – Riverside",
          context: "Schedules · Sep 27, 2:18 PM",
          detail: "6 trips changed on Weekday",
          route: @route,
          params: %{route_id: "12", service_id: "WKDY"},
          actor_email: "dana@northcoast.example",
          same_day_count: 3
        },
        overrides
      )
    )
  end

  defp check(overrides \\ %{}) do
    Map.merge(
      %{
        run_id: @check_run_id,
        errors: 0,
        warnings: 12,
        at: ~U[2026-09-26 17:02:00Z]
      },
      overrides
    )
  end

  defp export(overrides \\ %{}) do
    Map.merge(
      %{
        run_id: @export_run_id,
        type: :full,
        state: :ready,
        expired?: true,
        finished_at: ~U[2026-09-26 17:20:00Z]
      },
      overrides
    )
  end

  defp check_assigns(overrides \\ %{}) do
    Map.merge(
      %{
        version_id: @version_id,
        product: :planner,
        check: check(),
        export: export(),
        since: %{changes: 9, stations: 3}
      },
      overrides
    )
  end

  defp doc(html), do: LazyHTML.from_fragment(html)

  defp text(d, selector) do
    d |> LazyHTML.query(selector) |> LazyHTML.text() |> String.trim()
  end

  defp attr(d, selector, name) do
    d |> LazyHTML.query(selector) |> LazyHTML.attribute(name) |> List.first()
  end

  describe "home_page/1" do
    test "wraps the state in the page's design-system scope" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <GtfsPlannerWeb.Home.SharedComponents.home_page>
          <p id="state-content">September 2026 service</p>
        </GtfsPlannerWeb.Home.SharedComponents.home_page>
        """)

      d = doc(html)
      classes = attr(d, "#home-page", "class")

      assert classes =~ "font-ds"
      assert classes =~ "text-default"
      assert text(d, "#state-content") == "September 2026 service"
    end
  end

  describe "home_head/1" do
    test "renders the scope's name and lede as the page's heading" do
      html =
        render_component(&SharedComponents.home_head/1,
          title: "September 2026 service",
          lede: "Published Sep 2, 2026 · calendars run through Dec 31, 2026"
        )

      d = doc(html)

      assert text(d, "#home-title") == "September 2026 service"
      assert attr(d, "#home-title", "class") =~ "font-display"
      assert text(d, "#home-lede") =~ "calendars run through Dec 31, 2026"
    end
  end

  describe "resume_list/1" do
    test "renders the featured own item with its context line, day count and primary link" do
      html =
        render_component(&SharedComponents.resume_list/1, %{
          items: [{"resume-1", item()}],
          scope: :own,
          featured: schedules_item(),
          version_id: @version_id,
          primary?: true
        })

      d = doc(html)

      assert text(d, "#resume-title") == "Continue where you left off"
      assert text(d, "#resume-latest-context") == "Schedules · Sep 27, 2:18 PM"
      assert text(d, "#resume-latest") =~ "Downtown – Riverside"
      assert text(d, "#resume-latest") =~ "6 trips changed on Weekday · 3 changes that day"

      assert attr(d, "#resume-open", "href") ==
               "/gtfs/#{@version_id}/routes/12/schedules?service_id=WKDY"

      assert attr(d, "#resume-open", "class") =~ "bg-action"
      assert text(d, "#resume-open") == "Open schedules"
    end

    test "renders a secondary featured link when another region owns the primary" do
      html =
        render_component(&SharedComponents.resume_list/1, %{
          items: [],
          scope: :own,
          featured: schedules_item(),
          version_id: @version_id,
          primary?: false
        })

      classes = attr(doc(html), "#resume-open", "class")

      refute classes =~ "bg-action"
      assert classes =~ "border-control"
    end

    test "renders rows with the kind, change and local time" do
      html =
        render_component(&SharedComponents.resume_list/1, %{
          items: [{"resume-1", item()}],
          scope: :own,
          featured: nil,
          version_id: @version_id
        })

      d = doc(html)

      assert text(d, "li#resume-1 a") =~ "Weekday"
      assert text(d, "li#resume-1 a") =~ "Calendar · end date moved to Dec 31"
      assert text(d, "li#resume-1 a") =~ "Sep 27, 2:18 PM"

      assert attr(d, "li#resume-1 a", "href") ==
               "/gtfs/#{@version_id}/calendars/show?service_id=WKDY"
    end

    test "the team variant names the author of every row" do
      html =
        render_component(&SharedComponents.resume_list/1, %{
          items: [{"resume-1", item()}],
          scope: :team,
          featured: nil,
          version_id: @version_id
        })

      d = doc(html)

      assert text(d, "#resume-title") == "What your team changed recently"
      assert text(d, "li#resume-1 a") =~ "lee@northcoast.example"
      refute LazyHTML.query(d, "#resume-latest") |> Enum.any?()
    end

    test "an item whose entity is gone renders as text without a link" do
      removed = item(%{kind: :none, params: %{}, title: "Deleted route"})

      html =
        render_component(&SharedComponents.resume_list/1, %{
          items: [{"resume-1", removed}],
          scope: :own,
          featured: nil,
          version_id: @version_id
        })

      d = doc(html)

      assert text(d, "li#resume-1") =~ "Deleted route"
      refute LazyHTML.query(d, "li#resume-1 a") |> Enum.any?()
    end

    test "renders the empty copy when the version has no changes" do
      html =
        render_component(&SharedComponents.resume_list/1, %{
          items: [],
          scope: :team,
          featured: nil,
          version_id: @version_id
        })

      d = doc(html)
      empty = attr(d, "#resume-empty", "class")

      assert text(d, "#resume-empty") ==
               "Anything you change appears here, so you can come back to it."

      assert empty =~ "hidden"
      assert empty =~ "only:block"
    end

    test "the rows stream resets through the stream container" do
      html =
        render_component(&SharedComponents.resume_list/1, %{
          items: [{"resume-1", item()}],
          scope: :own,
          featured: nil,
          version_id: @version_id
        })

      d = doc(html)

      assert attr(d, "#resume-list", "phx-update") == "stream"
      assert attr(d, "li#resume-1", "id") == "resume-1"
    end
  end

  describe "check_and_share/1" do
    test "a check with only warnings uses the warning tone" do
      html = render_component(&SharedComponents.check_and_share/1, check_assigns())

      d = doc(html)

      assert text(d, "#check-badge") == "No errors · 12 warnings"
      assert attr(d, "#check-badge", "class") =~ "bg-warning-bg"
      assert text(d, "#check-note") =~ "do not stop apps from using the feed"
      assert text(d, "#check-link") == "View warnings"

      assert attr(d, "#check-link", "href") ==
               "/gtfs/#{@version_id}/validation/#{@check_run_id}"
    end

    test "a check with errors uses the error tone and the singular label" do
      html =
        render_component(
          &SharedComponents.check_and_share/1,
          check_assigns(%{check: check(%{errors: 1, warnings: 4})})
        )

      d = doc(html)

      assert text(d, "#check-badge") == "1 error · 4 warnings"
      assert attr(d, "#check-badge", "class") =~ "bg-error-bg"
      assert text(d, "#check-link") == "View the 1 error"
    end

    test "a clean check uses the success tone and links to its result" do
      html =
        render_component(
          &SharedComponents.check_and_share/1,
          check_assigns(%{check: check(%{errors: 0, warnings: 0})})
        )

      d = doc(html)

      assert text(d, "#check-badge") == "No errors · no warnings"
      assert attr(d, "#check-badge", "class") =~ "bg-success-bg"
      assert text(d, "#check-link") == "View the check"
      refute LazyHTML.query(d, "#check-note") |> Enum.any?()
    end

    test "an expired export shows the expired status, the changes since and the export action" do
      html = render_component(&SharedComponents.check_and_share/1, check_assigns())

      d = doc(html)

      assert text(d, "#export-meta") == "Full GTFS · Sep 26, 5:20 PM"
      assert text(d, "#export-status") == "Download expired"
      assert text(d, "#export-note") =~ "9 changes since then."
      assert text(d, "#export-note") =~ "downloads stay available for 24 hours"
      assert text(d, "#export-link") == "Export GTFS"
      assert attr(d, "#export-link", "href") == "/gtfs/#{@version_id}/export"
      assert attr(d, "#all-exports-link", "href") == "/gtfs/#{@version_id}/export"
      assert text(d, "#all-exports-link") == "All exports and checks"
    end

    test "a pathways export names its type and counts stations" do
      html =
        render_component(
          &SharedComponents.check_and_share/1,
          check_assigns(%{
            product: :pathways,
            export: export(%{type: :pathways, expired?: false}),
            since: %{changes: 31, stations: 6}
          })
        )

      d = doc(html)

      assert text(d, "#export-meta") == "Pathways export · Sep 26, 5:20 PM"
      assert text(d, "#export-status") == "Download available"
      assert text(d, "#export-note") =~ "31 changes since then across 6 stations."
      assert text(d, "#export-link") == "Export pathways"
    end

    test "no export names the product's missing export" do
      html =
        render_component(
          &SharedComponents.check_and_share/1,
          check_assigns(%{export: nil, since: nil})
        )

      d = doc(html)

      assert text(d, "#export-note") == "No Full GTFS export yet."
      refute LazyHTML.query(d, "#export-status") |> Enum.any?()
      assert text(d, "#export-link") == "Export GTFS"
    end

    test "no check says so without a result link" do
      html = render_component(&SharedComponents.check_and_share/1, check_assigns(%{check: nil}))

      d = doc(html)

      assert text(d, "#check-empty") == "No check yet. Run one from the export page."
      refute LazyHTML.query(d, "#check-link") |> Enum.any?()
      refute LazyHTML.query(d, "#check-badge") |> Enum.any?()
    end
  end

  describe "areas_strip/1" do
    test "a planner organization sees every area destination with its counts" do
      html =
        render_component(&SharedComponents.areas_strip/1,
          organization: planner_org(),
          version_id: @version_id,
          counts: %{routes: 14, calendars: 9, stations: 386}
        )

      d = doc(html)

      assert attr(d, "#area-routes", "href") == "/gtfs/#{@version_id}/routes"
      assert text(d, "#area-routes") =~ "Routes · 14"
      assert text(d, "#area-calendars") =~ "Calendars · 9"
      assert text(d, "#area-stops") =~ "Stops & stations · 386"
      assert attr(d, "#area-operations", "href") == "/gtfs/#{@version_id}/blocks"
      assert attr(d, "#area-gtfs", "href") == "/gtfs/#{@version_id}/export"
    end

    test "a pathways organization sees no Operations" do
      html =
        render_component(&SharedComponents.areas_strip/1,
          organization: pathways_org(),
          version_id: @version_id
        )

      d = doc(html)

      assert LazyHTML.query(d, "#area-routes") |> Enum.any?()
      refute LazyHTML.query(d, "#area-operations") |> Enum.any?()
      assert LazyHTML.query(d, "#area-gtfs") |> Enum.any?()
    end

    test "an absent count renders no number" do
      html =
        render_component(&SharedComponents.areas_strip/1,
          organization: planner_org(),
          version_id: @version_id
        )

      assert text(doc(html), "#area-routes") =~ "Routes"
      refute text(doc(html), "#area-routes") =~ "·"
    end
  end

  describe "people_row/1" do
    test "links organization administration to the users page" do
      d = doc(render_component(&SharedComponents.people_row/1, %{}))

      assert text(d, "#users-strip-title") == "People"
      assert text(d, "#users-strip") =~ "Invite colleagues and set who can edit"
      assert text(d, "#manage-users-link") == "Manage users"
      assert attr(d, "#manage-users-link", "href") == "/admin/users"
      assert attr(d, "#manage-users-link", "class") =~ "min-h-11"
    end
  end

  describe "region_error/1" do
    test "names what failed and retries only its region" do
      html =
        render_component(&SharedComponents.region_error/1,
          region: "resume",
          message: "Your recent changes could not load.",
          detail:
            "Routes, calendars and stops still open from the menu. Nothing you saved is affected."
        )

      d = doc(html)

      assert text(d, "#region-error-resume") =~ "Your recent changes could not load."
      assert text(d, "#region-error-resume") =~ "Nothing you saved is affected."
      assert attr(d, "#region-error-retry-resume", "phx-click") == "retry"
      assert attr(d, "#region-error-retry-resume", "phx-value-region") == "resume"
      assert text(d, "#region-error-retry-resume") == "Try again"
      assert attr(d, "#region-error-retry-resume", "class") =~ "min-h-11"
    end

    test "renders without a detail line" do
      html =
        render_component(&SharedComponents.region_error/1,
          region: "check",
          message: "Your checks could not load."
        )

      assert text(doc(html), "#region-error-check") =~ "Your checks could not load."
    end
  end

  describe "loading states" do
    test "the resume skeleton mirrors the card and its featured item plus four rows" do
      d = doc(render_component(&SharedComponents.resume_skeleton/1, %{}))

      assert text(d, "#resume-title") == "Continue where you left off"
      assert attr(d, "#resume-loading", "aria-hidden") == "true"
      assert attr(d, "#resume-loading", "class") =~ "animate-pulse"
      assert LazyHTML.query(d, "#resume-loading .min-h-16") |> length() == 4
      refute LazyHTML.query(d, "#resume-open") |> Enum.any?()
    end

    test "the check skeleton mirrors the share card and its footer" do
      d = doc(render_component(&SharedComponents.check_skeleton/1, %{version_id: @version_id}))

      assert text(d, "#share-title") == "Check and share this version"
      assert attr(d, "#share-loading", "aria-hidden") == "true"
      assert attr(d, "#share-loading", "class") =~ "animate-pulse"
      assert attr(d, "#all-exports-link", "href") == "/gtfs/#{@version_id}/export"
    end
  end
end
