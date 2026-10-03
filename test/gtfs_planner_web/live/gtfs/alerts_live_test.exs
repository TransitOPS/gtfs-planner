defmodule GtfsPlannerWeb.Gtfs.AlertsLiveTest do
  @moduledoc """
  Step 13: the Alerts list page renders the prototype's list without any
  publishing state, and Alerts is the first navigation task (AC-14, R2, CR-1).

  Every expectation is a literal from the spec's rules and the prototype, not a
  value recomputed by the module under test. The page reads the agency's own
  civil time, so the fixtures here answer `now` against the agency's date
  rather than a fixed date: an alert meant to be Current covers the agency's
  today, which is what `Alerts.Listing` groups on.

  The "active schedule" cases drive the real form, the real
  `Versions.set_active_schedule/3` and the organization's PubSub topic. A change
  the page was not told about is made by updating the pointer directly, because
  the broadcast is only a hint and the commands read the database.
  """

  use GtfsPlannerWeb.ConnCase, async: true

  import Ecto.Query, only: [from: 2]
  import Phoenix.LiveViewTest

  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.AlertsFixtures
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Alerts
  alias GtfsPlanner.Alerts.Publication
  alias GtfsPlanner.Gtfs.AuditContext
  alias GtfsPlanner.Gtfs.DisplayClock
  alias GtfsPlanner.Gtfs.Stop
  alias GtfsPlanner.Organizations.Organization
  alias GtfsPlanner.Repo
  alias GtfsPlanner.Versions

  # The words this package must never show on an alerts surface: the publication
  # states and actions of the prototype's earlier revision, which package 30
  # removed because saving an alert never publishes one (R2, CR-1).
  @publication_copy ["Live", "Scheduled", "Ended", "End alert", "feed"]

  setup do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    actor = editor_fixture(organization)
    agency_fixture(organization.id, version.id, %{agency_timezone: "America/Los_Angeles"})

    # The list resolves every alert's routes against the active schedule.
    activate_version!(organization, version, actor)

    %{
      organization: organization,
      version: version,
      actor: actor,
      audit: audit_context(organization, version, actor)
    }
  end

  describe "the page as an editor" do
    setup :editor_conn

    test "renders the page with Create alert and Alerts current in the navigation", context do
      {:ok, view, _html} = live(context.conn, alerts_path())

      assert has_element?(view, "#alerts-page")
      assert has_element?(view, "#create-alert-first-use", "Create alert")
      assert has_element?(view, "#main-navigation #nav-alerts[aria-current='page']")
    end

    test "the four tabs carry the counts the read model derived", context do
      _incomplete = incomplete(context)
      {:ok, _current} = current_delay(context)

      {:ok, view, _html} = live(context.conn, alerts_path())

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
        live(context.conn, alerts_path() <> "?tab=in_progress")

      assert has_element?(view, "#alert-row-#{incomplete.id}", "Incomplete")
      refute has_element?(view, "#alert-row-#{current.id}")
      assert has_element?(view, "#alerts-tab-in_progress[aria-selected='true']")
    end

    test "switching between two populated tabs replaces the previous tab's rows", context do
      incomplete = incomplete(context)
      {:ok, current} = current_delay(context)

      {:ok, view, _html} = live(context.conn, alerts_path())

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
        live(context.conn, alerts_path() <> "?tab=nonsense")

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
            "scope" => %{"shape" => "stop_all_routes", "stop_ids" => [stop.stop_id]},
            "message" => message()
          },
          now_timing(context)
        )

      {:ok, view, _html} = live(context.conn, alerts_path())

      refute has_element?(view, "[data-role='alert-needs-attention']")

      Stop
      |> Repo.get!(stop.id)
      |> Repo.delete!()

      {:ok, view, _html} = live(context.conn, alerts_path())

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

      {:ok, view, _html} = live(context.conn, alerts_path())

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
            "scope" => %{"shape" => "stop_all_routes", "stop_ids" => [stop.stop_id, stop.stop_id]},
            "message" => message()
          },
          now_timing(context)
        )

      {:ok, view, _html} = live(context.conn, alerts_path())

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
              "route_ids" => [chosen.route_id],
              "stop_ids" => [stop.stop_id],
              "route_stop_pairs" => [%{"route_id" => paired.route_id, "stop_id" => stop.stop_id}]
            },
            "message" => message()
          },
          now_timing(context)
        )

      {:ok, view, _html} = live(context.conn, alerts_path())

      # The paired route is affected at the stop, so the row names it beside the
      # route the editor chose.
      assert has_element?(view, "#alert-row-#{alert.id}", "11")
      assert has_element?(view, "#alert-row-#{alert.id}", "22")
    end

    test "a route ID two source versions share shows the active schedule's route on each alert",
         context do
      other = gtfs_version_fixture(context.organization.id)

      agency_fixture(context.organization.id, other.id, %{agency_timezone: "America/Los_Angeles"})

      route_fixture(context.organization.id, context.version.id, %{
        route_id: "r_1",
        route_short_name: "XT"
      })

      route_fixture(context.organization.id, other.id, %{route_id: "r_1", route_short_name: "LK"})

      {:ok, here} =
        save(context.audit, route_delay("r_1"), now_timing(context))

      {:ok, there} =
        save(
          audit_context(context.organization, other, context.actor),
          route_delay("r_1"),
          now_timing(context)
        )

      activate_version!(context.organization, context.version, context.actor)

      {:ok, view, _html} = live(context.conn, alerts_path())

      # Both resolve against the active version, so the alert written against the
      # sibling reads the active route and its own source version's `LK` is unused.
      assert has_element?(view, "#alert-row-#{here.id}", "XT")
      assert has_element?(view, "#alert-row-#{there.id}", "XT")
      refute has_element?(view, "#alert-row-#{there.id}", "LK")
      refute has_element?(view, "[data-role='alert-needs-attention']")
    end

    test "an organization with no active schedule lists no alerts and offers no create",
         context do
      {:ok, _current} = current_delay(context)

      Repo.update_all(
        from(o in GtfsPlanner.Organizations.Organization,
          where: o.id == ^context.organization.id
        ),
        set: [active_gtfs_version_id: nil]
      )

      {:ok, view, _html} = live(context.conn, alerts_path())

      assert has_element?(view, "#alerts-no-active")
      refute has_element?(view, "#alerts-list")
      refute has_element?(view, "#alerts-tabs")
      refute has_element?(view, "#alerts-first-use")
      refute has_element?(view, "#create-alert")
      refute has_element?(view, "#create-alert-first-use")
    end

    test "a draft with no route answer does not read All routes", context do
      draft = incomplete(context)
      {:ok, current} = current_delay(context)

      {:ok, view, _html} =
        live(context.conn, alerts_path() <> "?tab=in_progress")

      assert has_element?(view, "#alert-row-#{draft.id}", "Incomplete")
      refute has_element?(view, "#alert-row-#{draft.id}", "All routes")

      # An alert that chose the whole system still reads All routes.
      {:ok, view, _html} = live(context.conn, alerts_path())

      assert has_element?(view, "#alert-row-#{current.id}", "All routes")
    end

    test "the page carries no publication state or action", context do
      {:ok, _current} = current_delay(context)

      {:ok, _view, html} = live(context.conn, alerts_path())
      text = LazyHTML.text(LazyHTML.from_fragment(html))

      for word <- @publication_copy do
        refute text =~ word, "expected no #{word} on the alerts list"
      end
    end

    test "the mobile rows carry the same words as the table", context do
      {:ok, current} = current_delay(context)

      {:ok, view, _html} = live(context.conn, alerts_path())

      assert has_element?(
               view,
               "#alerts-mobile #alert-card-#{current.id}",
               current.message.header
             )

      assert has_element?(view, "#alerts-mobile #alert-card-#{current.id}", "Check-in at")
    end
  end

  describe "the active schedule" do
    setup :editor_conn

    test "names the active schedule and never the version the header shows", context do
      # The newest published version is the one the header shows for this reader.
      _header = gtfs_version_fixture(context.organization.id, %{name: "Header version"})

      {:ok, view, _html} = live(context.conn, alerts_path())

      assert has_element?(view, "#gtfs-version-trigger[aria-label='Version, Header version']")
      assert has_element?(view, "#alerts-active-name", context.version.name)
      refute has_element?(view, "#alerts-active-name", "Header version")

      assert has_element?(
               view,
               "#alerts-active-schedule-version option[selected][value='#{context.version.id}']"
             )
    end

    test "offers no selection when the active schedule is the only published one", context do
      Repo.delete_all(
        from(v in GtfsPlanner.Versions.GtfsVersion,
          where: v.organization_id == ^context.organization.id and v.id != ^context.version.id
        )
      )

      {:ok, view, _html} = live(context.conn, alerts_path())

      assert has_element?(view, "#alerts-active-name", context.version.name)
      refute has_element?(view, "#alerts-active-schedule")
    end

    test "choosing another schedule moves the labels, the attention state and the token",
         context do
      other = second_schedule(context, "Spring service")

      route_fixture(context.organization.id, context.version.id, %{
        route_id: "r_1",
        route_short_name: "XT"
      })

      route_fixture(context.organization.id, other.id, %{route_id: "r_1", route_short_name: "LK"})
      stop_fixture(context.organization.id, context.version.id, %{stop_id: "s_1"})

      {:ok, by_route} = save(context.audit, route_delay("r_1"), now_timing(context))
      {:ok, by_stop} = save(context.audit, stop_closed("s_1"), now_timing(context))

      # An accepted public snapshot, to show the selection does not touch it.
      accepted = accepted_snapshot!(by_route, context.actor)

      {:ok, %{token: before_token}} = Versions.active_schedule(context.audit)
      {:ok, view, _html} = live(context.conn, alerts_path())

      assert has_element?(view, "#alert-row-#{by_route.id}", "XT")
      refute has_element?(view, "#alert-row-#{by_stop.id} [data-role='alert-needs-attention']")
      refute has_element?(view, "[data-role='alert-target-notes']")

      view |> element("#alerts-active-toggle") |> render_click()
      assert has_element?(view, "#alerts-active-more[open]")

      view
      |> form("#alerts-active-schedule", active_schedule: %{version_id: other.id})
      |> render_submit()

      assert has_element?(view, "#alerts-active-name", "Spring service")
      refute has_element?(view, "#alerts-active-more[open]")
      assert has_element?(view, "#alert-row-#{by_route.id}", "LK")
      refute has_element?(view, "#alert-row-#{by_route.id}", "XT")

      # The stop is only in the previous schedule, so the alert that names it needs
      # attention and the row spells out the feed ID it kept.
      assert has_element?(
               view,
               "#alert-row-#{by_stop.id} [data-role='alert-needs-attention']",
               "Needs attention"
             )

      assert has_element?(
               view,
               "#alert-row-#{by_stop.id} [data-role='alert-target-notes']",
               "Stop s_1 is not in the active schedule"
             )

      assert has_element?(
               view,
               "#alerts-active-schedule-version option[selected][value='#{other.id}']"
             )

      assert_push_event(view, "focus_scoped_target", %{id: "alerts-active-name"})

      # One selection change moved the pointer once, and the accepted snapshot is the
      # row it was before.
      assert {:ok, %{version: %{id: other_id}, token: after_token}} =
               Versions.active_schedule(context.audit)

      assert other_id == other.id
      assert after_token.revision == before_token.revision + 1
      assert Repo.get!(Publication, accepted.id) == accepted
    end

    test "a change committed elsewhere reloads the rows, counts and labels together", context do
      other = second_schedule(context, "Spring service")
      stop_fixture(context.organization.id, context.version.id, %{stop_id: "s_1"})
      {:ok, by_stop} = save(context.audit, stop_closed("s_1"), now_timing(context))

      {:ok, view, _html} = live(context.conn, alerts_path())

      refute has_element?(view, "[data-role='alert-needs-attention']")
      refute has_element?(view, "#alerts-active-more[open]")

      # An editor who is choosing keeps the form open through someone else's change.
      view |> element("#alerts-active-toggle") |> render_click()
      assert has_element?(view, "#alerts-active-more[open]")

      {:ok, _active} = switch_schedule(context, other)

      assert has_element?(view, "#alerts-active-more[open]")
      assert has_element?(view, "#alerts-active-name", "Spring service")
      assert has_element?(view, "#alert-row-#{by_stop.id} [data-role='alert-needs-attention']")
      assert has_element?(view, "#alerts-tab-current[data-count='1']")
    end

    test "a notification that is not newer than the page's token reloads nothing", context do
      other = second_schedule(context, "Spring service")
      {:ok, view, _html} = live(context.conn, alerts_path())
      {:ok, %{token: held}} = Versions.active_schedule(context.audit)

      # Move the selection without the broadcast the commands send, so only a
      # reload can show it.
      move_without_notice(context, other, held.revision + 1)

      send(view.pid, {:active_schedule_changed, held})
      assert has_element?(view, "#alerts-active-name", context.version.name)

      send(
        view.pid,
        {:active_schedule_changed, %{version_id: other.id, revision: held.revision + 1}}
      )

      assert has_element?(view, "#alerts-active-name", "Spring service")
    end

    test "a submit built on a change the page missed is refused and keeps the choice",
         context do
      chosen = second_schedule(context, "Spring service")
      current = second_schedule(context, "Summer service")

      {:ok, view, _html} = live(context.conn, alerts_path())

      # The broadcast is only a hint: the commands read the database.
      move_without_notice(context, current, 99)

      view
      |> form("#alerts-active-schedule", active_schedule: %{version_id: chosen.id})
      |> render_submit()

      assert has_element?(view, "#alerts-active-schedule-version[aria-invalid='true']")

      assert has_element?(view, "#alerts-active-more[open]")

      assert has_element?(
               view,
               "#alerts-active-schedule-version-error",
               "changed since you opened"
             )

      assert has_element?(view, "#alerts-active-name", "Summer service")

      assert has_element?(
               view,
               "#alerts-active-schedule-version option[selected][value='#{chosen.id}']"
             )

      assert_push_event(view, "focus_form_error", %{form_id: "alerts-active-schedule"})

      assert {:ok, %{version: %{id: current_id}, token: %{revision: 99}}} =
               Versions.active_schedule(context.audit)

      assert current_id == current.id
    end

    test "forged selections are refused and leave the selection alone", context do
      {:ok, %{token: before_token}} = Versions.active_schedule(context.audit)

      foreign_org = organization_fixture()
      foreign = gtfs_version_fixture(foreign_org.id, %{name: "Foreign schedule"})

      {:ok, staging} =
        Versions.create_staging_gtfs_version(context.organization.id, %{name: "Staging"})

      {:ok, view, _html} = live(context.conn, alerts_path())

      for forged <- [foreign.id, staging.id, Ecto.UUID.generate(), "not-a-uuid", ""] do
        render_hook(view, "set_active_schedule", %{"active_schedule" => %{"version_id" => forged}})

        assert has_element?(view, "#alerts-active-schedule-version-error"),
               "expected a refusal for #{inspect(forged)}"

        assert has_element?(view, "#alerts-active-name", context.version.name)
        assert {:ok, %{token: ^before_token}} = Versions.active_schedule(context.audit)
      end

      render_hook(view, "set_active_schedule", %{"unexpected" => "shape"})

      assert has_element?(view, "#alerts-active-schedule-version-error")
      assert {:ok, %{token: ^before_token}} = Versions.active_schedule(context.audit)
    end

    test "a choice by an editor whose role was revoked is refused and the page is unavailable",
         context do
      other = second_schedule(context, "Spring service")
      {:ok, %{token: before_token}} = Versions.active_schedule(context.audit)
      {:ok, view, _html} = live(context.conn, alerts_path())

      Repo.update_all(
        from(m in GtfsPlanner.Accounts.UserOrgMembership, where: m.user_id == ^context.actor.id),
        set: [roles: []]
      )

      render_hook(view, "set_active_schedule", %{"active_schedule" => %{"version_id" => other.id}})

      assert has_element?(view, "#alerts-unavailable")
      refute has_element?(view, "#alerts-active-schedule")
      refute has_element?(view, "#alerts-list")
      refute has_element?(view, "#create-alert")

      # The refused choice moved nothing.
      organization = Repo.get!(Organization, context.organization.id)
      assert organization.active_gtfs_version_id == before_token.version_id
      assert organization.active_gtfs_version_revision == before_token.revision
    end

    test "an organization with no active schedule can choose one from the published ones",
         context do
      other = second_schedule(context, "Spring service")
      clear_pointer(context)

      {:ok, view, _html} = live(context.conn, alerts_path())

      assert has_element?(view, "#alerts-no-active", "No active schedule")

      assert has_element?(
               view,
               "#alerts-active-schedule-version option[value='']",
               "Choose a schedule"
             )

      refute has_element?(view, "#alerts-list")
      refute has_element?(view, "#create-alert")
      refute has_element?(view, "#create-alert-first-use")

      view
      |> form("#alerts-active-schedule", active_schedule: %{version_id: other.id})
      |> render_submit()

      refute has_element?(view, "#alerts-no-active")
      assert has_element?(view, "#alerts-active-name", "Spring service")
      assert has_element?(view, "#create-alert-first-use")
      assert {:ok, %{version: %{id: chosen}}} = Versions.active_schedule(context.audit)
      assert chosen == other.id
    end

    test "an organization with no published schedule offers no selection and no create" do
      organization = organization_fixture()
      actor = editor_fixture(organization)

      delete_versions!(
        from(v in GtfsPlanner.Versions.GtfsVersion, where: v.organization_id == ^organization.id)
      )

      {:ok, _staging} = Versions.create_staging_gtfs_version(organization.id, %{name: "Staging"})

      conn = log_in_user(build_conn(), actor, organization: organization)
      {:ok, view, _html} = live(conn, alerts_path())

      assert has_element?(view, "#alerts-no-active", "no published schedule")
      refute has_element?(view, "#alerts-active-schedule")
      refute has_element?(view, "#alerts-list")
      refute has_element?(view, "#create-alert")
      refute has_element?(view, "#create-alert-first-use")

      # With no published schedule there is nothing to submit against.
      render_hook(view, "set_active_schedule", %{
        "active_schedule" => %{"version_id" => Ecto.UUID.generate()}
      })

      assert has_element?(view, "#alerts-no-active")
    end
  end

  describe "empty states" do
    setup :editor_conn

    test "an organization with no alerts gets the first-use panel", context do
      {:ok, view, _html} = live(context.conn, alerts_path())

      assert has_element?(view, "#alerts-first-use", "No alerts yet")
      assert has_element?(view, "#create-alert-first-use", "Create alert")
      refute has_element?(view, "#alerts-list")
      refute has_element?(view, "#create-alert")
    end

    test "an empty tab gets its own message rather than the first-use panel", context do
      {:ok, _current} = current_delay(context)

      {:ok, view, _html} = live(context.conn, alerts_path() <> "?tab=upcoming")

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

      {:ok, view, _html} = live(conn, alerts_path())

      assert has_element?(view, "#main-navigation #nav-alerts", "Alerts")
    end

    test "a version with no agency still renders the first-use panel", _context do
      # The Pathways product has no agency row, so the display clock falls back to
      # UTC for the list's tabs and times.
      pathways = organization_fixture(%{product: :pathways})
      actor = editor_fixture(pathways)
      gtfs_version_fixture(pathways.id)

      conn = log_in_user(build_conn(), actor, organization: pathways)

      {:ok, view, _html} = live(conn, alerts_path())

      assert has_element?(view, "#alerts-first-use", "No alerts yet")
      assert has_element?(view, "#create-alert-first-use", "Create alert")
    end

    test "a member without the editor role is refused the list", context do
      viewer = user_fixture()
      organization_membership_fixture(viewer, context.organization, [])
      conn = log_in_user(build_conn(), viewer, organization: context.organization)

      assert {:error, {:redirect, %{to: path}}} = live(conn, alerts_path())
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

  defp alerts_path, do: "/alerts"

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

  defp route_delay(route_id) do
    %{
      "urgency" => "now",
      "situation" => "delay",
      "cause" => "weather",
      "scope" => %{"shape" => "routes", "route_ids" => [route_id]},
      "message" => message()
    }
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

  # A second published schedule in the organization, with the agency zone the
  # fixture's schedule has so an alert written against either reads the same day.
  defp second_schedule(context, name) do
    other = gtfs_version_fixture(context.organization.id, %{name: name})
    agency_fixture(context.organization.id, other.id, %{agency_timezone: "America/Los_Angeles"})
    other
  end

  defp switch_schedule(context, version) do
    scope = %{actor_id: context.actor.id, organization_id: context.organization.id}
    {:ok, %{token: token}} = Versions.active_schedule(scope)
    Versions.set_active_schedule(scope, version.id, token)
  end

  # A selection the page was not told about: no broadcast leaves this update.
  defp move_without_notice(context, version, revision) do
    Repo.update_all(
      from(o in Organization, where: o.id == ^context.organization.id),
      set: [active_gtfs_version_id: version.id, active_gtfs_version_revision: revision]
    )
  end

  # The legacy state a published schedule can sit in with no pointer.
  defp clear_pointer(context) do
    Repo.update_all(
      from(o in Organization, where: o.id == ^context.organization.id),
      set: [active_gtfs_version_id: nil]
    )
  end

  defp stop_closed(stop_id) do
    %{
      "urgency" => "now",
      "situation" => "stop_closed",
      "cause" => "construction",
      "scope" => %{"shape" => "stop_all_routes", "stop_ids" => [stop_id]},
      "message" => message()
    }
  end

  # The public intent an accepted alert holds, written directly because only the
  # row's survival matters here, not how it was produced.
  defp accepted_snapshot!(alert, actor) do
    Repo.insert!(%Publication{
      organization_id: alert.organization_id,
      alert_id: alert.id,
      desired_revision: alert.revision,
      desired_snapshot: %{"accepted_revision" => alert.revision},
      confirmed_revision: alert.revision,
      confirmed_snapshot: %{"accepted_revision" => alert.revision},
      requested_by_id: actor.id,
      requested_at: DateTime.utc_now(),
      last_published_at: DateTime.utc_now(),
      withdrawal: :none
    })
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
