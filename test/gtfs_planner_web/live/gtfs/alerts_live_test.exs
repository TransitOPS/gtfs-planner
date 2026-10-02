defmodule GtfsPlannerWeb.Gtfs.AlertsLiveTest do
  @moduledoc """
  Step 13: the Alerts list page renders the prototype's list without any
  publishing state, and Alerts is the first navigation task (AC-14, R2, CR-1).

  Every expectation is a literal from the spec's rules and the prototype, not a
  value recomputed by the module under test. The page reads the agency's own
  civil time, so the fixtures here answer `now` against the agency's date
  rather than a fixed date: an alert meant to be Current covers the agency's
  today, which is what `Alerts.Listing` groups on.
  """

  use GtfsPlannerWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.AlertsFixtures
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Alerts
  alias GtfsPlanner.Gtfs.AuditContext
  alias GtfsPlanner.Gtfs.DisplayClock
  alias GtfsPlanner.Gtfs.Stop
  alias GtfsPlanner.Repo

  # The words this package must never show on an alerts surface: the publication
  # states and actions of the prototype's earlier revision, which package 30
  # removed because saving an alert never publishes one (R2, CR-1).
  @publication_copy ["Live", "Scheduled", "Ended", "End alert", "feed"]

  setup do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    actor = editor_fixture(organization)
    agency_fixture(organization.id, version.id, %{agency_timezone: "America/Los_Angeles"})

    %{
      organization: organization,
      version: version,
      actor: actor,
      audit: audit_context(organization, version, actor)
    }
  end

  describe "the page as an editor" do
    setup :editor_conn

    test "renders the page with Create alert and Alerts first in the navigation", context do
      {:ok, view, _html} = live(context.conn, alerts_path(context.version))

      assert has_element?(view, "#alerts-page")
      assert has_element?(view, "#create-alert-first-use", "Create alert")

      assert ["nav-alerts" | _rest] =
               view
               |> render()
               |> LazyHTML.from_fragment()
               |> LazyHTML.query("#main-navigation a")
               |> Enum.map(&List.first(LazyHTML.attribute(&1, "id")))
    end

    test "the four tabs carry the counts the read model derived", context do
      _incomplete = incomplete(context)
      {:ok, _current} = current_delay(context)

      {:ok, view, _html} = live(context.conn, alerts_path(context.version))

      assert has_element?(view, "#alerts-tabs[role='tablist'] #alerts-tab-current[role='tab']")
      assert has_element?(view, "#alerts-tab-current[data-count='1']")
      assert has_element?(view, "#alerts-tab-in_progress[data-count='1']")
      assert has_element?(view, "#alerts-tab-upcoming[data-count='0']")
      assert has_element?(view, "#alerts-tab-past[data-count='0']")
    end

    test "?tab=in_progress lists only the incomplete row", context do
      incomplete = incomplete(context)
      {:ok, current} = current_delay(context)

      {:ok, view, _html} =
        live(context.conn, alerts_path(context.version) <> "?tab=in_progress")

      assert has_element?(view, "#alert-row-#{incomplete.id}", "Incomplete")
      refute has_element?(view, "#alert-row-#{current.id}")
      assert has_element?(view, "#alerts-tab-in_progress[aria-selected='true']")
    end

    test "switching between two populated tabs replaces the previous tab's rows", context do
      incomplete = incomplete(context)
      {:ok, current} = current_delay(context)

      {:ok, view, _html} = live(context.conn, alerts_path(context.version))

      assert has_element?(view, "#alert-row-#{current.id}")
      assert has_element?(view, "#alert-card-#{current.id}")

      view |> element("#alerts-tab-in_progress") |> render_click()

      assert has_element?(view, "#alert-row-#{incomplete.id}")
      assert has_element?(view, "#alert-card-#{incomplete.id}")
      refute has_element?(view, "#alert-row-#{current.id}")
      refute has_element?(view, "#alert-card-#{current.id}")

      view |> element("#alerts-tab-current") |> render_click()

      assert has_element?(view, "#alert-row-#{current.id}")
      assert has_element?(view, "#alert-card-#{current.id}")
      refute has_element?(view, "#alert-row-#{incomplete.id}")
      refute has_element?(view, "#alert-card-#{incomplete.id}")
    end

    test "an unknown tab falls back to Current rather than raising", context do
      {:ok, current} = current_delay(context)

      {:ok, view, _html} =
        live(context.conn, alerts_path(context.version) <> "?tab=nonsense")

      assert has_element?(view, "#alert-row-#{current.id}")
      assert has_element?(view, "#alerts-tab-current[aria-selected='true']")
    end

    test "a row whose stop was deleted shows Needs attention", context do
      stop = stop_fixture(context.organization.id, context.version.id, %{stop_id: "s_1"})

      {:ok, _alert} =
        save(
          context.audit,
          %{
            "urgency" => "now",
            "situation" => "stop_closed",
            "cause" => "construction",
            "scope" => %{"shape" => "stop_all_routes", "stop_ids" => [stop.id]},
            "message" => message()
          },
          now_timing(context)
        )

      {:ok, view, _html} = live(context.conn, alerts_path(context.version))

      refute has_element?(view, "[data-role='alert-needs-attention']")

      Stop
      |> Repo.get!(stop.id)
      |> Repo.delete!()

      {:ok, view, _html} = live(context.conn, alerts_path(context.version))

      assert has_element?(view, "[data-role='alert-needs-attention']", "Needs attention")
    end

    test "a row whose check-in has arrived shows Check-in due", context do
      now = Alerts.agency_now(context.audit)

      timing = %{
        "start_date" => now |> NaiveDateTime.to_date() |> Date.to_iso8601(),
        "start_time" => "00:00:00",
        "end_kind" => "estimated",
        "check_in_at" => now |> NaiveDateTime.add(-3_600) |> NaiveDateTime.to_iso8601()
      }

      {:ok, _alert} =
        save(
          context.audit,
          %{
            "urgency" => "now",
            "situation" => "delay",
            "cause" => "weather",
            "scope" => %{"shape" => "system"},
            "message" => message()
          },
          timing
        )

      {:ok, view, _html} = live(context.conn, alerts_path(context.version))

      assert has_element?(view, "[data-role='alert-check-in-due']", "Check-in due")
    end

    test "an alert that names no route shows All routes and a stop count", context do
      stop = stop_fixture(context.organization.id, context.version.id, %{stop_id: "s_1"})
      _other = stop_fixture(context.organization.id, context.version.id, %{stop_id: "s_2"})

      {:ok, _alert} =
        save(
          context.audit,
          %{
            "urgency" => "now",
            "situation" => "stop_closed",
            "cause" => "construction",
            "scope" => %{"shape" => "stop_all_routes", "stop_ids" => [stop.id, stop.id]},
            "message" => message()
          },
          now_timing(context)
        )

      {:ok, view, _html} = live(context.conn, alerts_path(context.version))

      assert has_element?(view, "#alerts-list", "All routes")
      assert has_element?(view, "#alerts-list", "1 stop")
    end

    test "a route named only by a route and stop pair is on the row", context do
      stop = stop_fixture(context.organization.id, context.version.id, %{stop_id: "s_1"})

      chosen =
        route_fixture(context.organization.id, context.version.id, %{
          route_id: "r_1",
          route_short_name: "11"
        })

      paired =
        route_fixture(context.organization.id, context.version.id, %{
          route_id: "r_2",
          route_short_name: "22"
        })

      {:ok, alert} =
        save(
          context.audit,
          %{
            "urgency" => "now",
            "situation" => "detour",
            "cause" => "construction",
            "scope" => %{
              "shape" => "route_stops",
              "route_ids" => [chosen.id],
              "stop_ids" => [stop.id],
              "route_stop_pairs" => [%{"route_id" => paired.id, "stop_id" => stop.id}]
            },
            "message" => message()
          },
          now_timing(context)
        )

      {:ok, view, _html} = live(context.conn, alerts_path(context.version))

      # The paired route is affected at the stop, so the row names it beside the
      # route the editor chose.
      assert has_element?(view, "#alert-row-#{alert.id}", "11")
      assert has_element?(view, "#alert-row-#{alert.id}", "22")
    end

    test "a draft with no route answer does not read All routes", context do
      draft = incomplete(context)
      {:ok, current} = current_delay(context)

      {:ok, view, _html} =
        live(context.conn, alerts_path(context.version) <> "?tab=in_progress")

      assert has_element?(view, "#alert-row-#{draft.id}", "Incomplete")
      refute has_element?(view, "#alert-row-#{draft.id}", "All routes")

      # An alert that chose the whole system still reads All routes.
      {:ok, view, _html} = live(context.conn, alerts_path(context.version))

      assert has_element?(view, "#alert-row-#{current.id}", "All routes")
    end

    test "the page carries no publication state or action", context do
      {:ok, _current} = current_delay(context)

      {:ok, _view, html} = live(context.conn, alerts_path(context.version))
      text = LazyHTML.text(LazyHTML.from_fragment(html))

      for word <- @publication_copy do
        refute text =~ word, "expected no #{word} on the alerts list"
      end
    end

    test "the mobile rows carry the same words as the table", context do
      {:ok, current} = current_delay(context)

      {:ok, view, _html} = live(context.conn, alerts_path(context.version))

      assert has_element?(
               view,
               "#alerts-mobile #alert-card-#{current.id}",
               current.message.header
             )

      assert has_element?(view, "#alerts-mobile #alert-card-#{current.id}", "Check-in at")
    end
  end

  describe "empty states" do
    setup :editor_conn

    test "an organization with no alerts gets the first-use panel", context do
      {:ok, view, _html} = live(context.conn, alerts_path(context.version))

      assert has_element?(view, "#alerts-first-use", "No alerts yet")
      assert has_element?(view, "#create-alert-first-use", "Create alert")
      refute has_element?(view, "#alerts-list")
      refute has_element?(view, "#create-alert")
    end

    test "an empty tab gets its own message rather than the first-use panel", context do
      {:ok, _current} = current_delay(context)

      {:ok, view, _html} = live(context.conn, alerts_path(context.version) <> "?tab=upcoming")

      refute has_element?(view, "#alerts-first-use")
      assert has_element?(view, "#alerts-tab-empty-upcoming", "Nothing is planned yet")
      refute has_element?(view, "#alerts-tab-empty-current")
    end
  end

  describe "access" do
    test "a Pathways Studio editor also sees Alerts in the navigation", _context do
      pathways = organization_fixture(%{product: :pathways})
      actor = editor_fixture(pathways)
      version = gtfs_version_fixture(pathways.id)
      agency_fixture(pathways.id, version.id)

      conn = log_in_user(build_conn(), actor, organization: pathways)

      {:ok, view, _html} = live(conn, alerts_path(version))

      assert has_element?(view, "#main-navigation #nav-alerts", "Alerts")
    end

    test "a version with no agency still renders the first-use panel", _context do
      # The Pathways product has no agency row, so the display clock falls back to
      # UTC for the list's tabs and times.
      pathways = organization_fixture(%{product: :pathways})
      actor = editor_fixture(pathways)
      version = gtfs_version_fixture(pathways.id)

      conn = log_in_user(build_conn(), actor, organization: pathways)

      {:ok, view, _html} = live(conn, alerts_path(version))

      assert has_element?(view, "#alerts-first-use", "No alerts yet")
      assert has_element?(view, "#create-alert-first-use", "Create alert")
    end

    test "a member without the editor role is refused the list", context do
      viewer = user_fixture()
      organization_membership_fixture(viewer, context.organization, [])
      conn = log_in_user(build_conn(), viewer, organization: context.organization)

      assert {:error, {:redirect, %{to: path}}} = live(conn, alerts_path(context.version))
      assert path == "/admin/organizations"
    end
  end

  # -- Fixtures ------------------------------------------------------------

  defp editor_conn(context) do
    %{
      context
      | conn: log_in_user(build_conn(), context.actor, organization: context.organization)
    }
  end

  defp alerts_path(version), do: "/gtfs/#{version.id}/alerts"

  # The agency's own date, because the tabs are grouped on it rather than on
  # UTC's (CR-7).
  defp agency_today(context) do
    DisplayClock.today(context.organization.id, context.version.id).date
  end

  # A complete alert covering the agency's today, so `Alerts.Listing` reads it as
  # Current without this test recomputing a tab.
  defp current_delay(context) do
    attrs = %{
      "urgency" => "now",
      "situation" => "delay",
      "cause" => "weather",
      "scope" => %{"shape" => "system"},
      "message" => message()
    }

    save(context.audit, attrs, now_timing(context))
  end

  # A draft that has answered one question and no more, so the read model reads
  # it as In progress rather than as a Current alert with no timing.
  defp incomplete(context) do
    alert_fixture(context.audit, %{"urgency" => "now"})
  end

  defp now_timing(context) do
    %{
      "start_date" => Date.to_iso8601(agency_today(context)),
      "start_time" => "08:00:00",
      "end_kind" => "estimated",
      "check_in_at" =>
        NaiveDateTime.to_iso8601(NaiveDateTime.new!(agency_today(context), ~T[20:00:00]))
    }
  end

  defp save(audit, attrs, timing) do
    alert = alert_fixture(audit, attrs)

    assert {:ok, saved} =
             Alerts.save_draft(
               audit,
               alert.id,
               alert.revision,
               Map.put(attrs, "timing", timing)
             )

    {:ok, saved}
  end

  defp message do
    %{
      "header" => "Route 1 buses delayed",
      "description" => "Water main work on Main St. Use Route 2 instead."
    }
  end

  defp audit_context(organization, version, actor) do
    %AuditContext{
      organization_id: organization.id,
      gtfs_version_id: version.id,
      station_stop_id: nil,
      actor_id: actor.id,
      actor_email: actor.email
    }
  end
end
