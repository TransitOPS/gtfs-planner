defmodule GtfsPlannerWeb.Gtfs.AlertEditorMessageTest do
  @moduledoc """
  Step 21: the message step offers this organization's scripts with the alert's
  own situation first, fills the text from the alert's facts, and never
  overwrites wording somebody wrote (AC-22, FH-22).

  Every expectation is a literal: the prototype's script list and its wording
  panel, the specification's advisory rules (a header over 60 characters, a
  description that says when), the guidelines text the built-in scripts ship, and
  this fixture's own route, stops and schedule. Nothing here recomputes an
  expectation with the module under test.

  The ids are the ones the templates give each control, so nothing depends on
  copy or layout. The alert is written only through `Alerts.create_alert/2` and
  `Alerts.save_draft/4` (INV-1), and read back through `Alerts.get_alert/2`.
  """

  use GtfsPlannerWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.AlertsFixtures
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Alerts
  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.AuditContext

  # The built-in detour script's templates, filled from this fixture's own
  # answers: Route 1, NE 6th St to NE 20th St, a Monday-to-Friday 8 PM to 5 AM
  # run, Lincoln City as the destination and roadwork as the reason.
  @detour_header "Route 1 detour: NE 6th St to NE 20th St not served"

  @detour_description "Mon–Fri, 8 PM to 5 AM the next day, Oct 5 to Oct 23, " <>
                        "Route 1 buses to Lincoln City are detoured because of roadwork. " <>
                        "Stops from NE 6th St to NE 20th St are not served."

  setup do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id, %{name: "Fall 2026 service"})
    actor = editor_fixture(organization)

    agency_fixture(organization.id, version.id, %{agency_timezone: "America/Los_Angeles"})

    %{first: first, middle: middle, last: last} =
      stops(organization, version, [
        {"S6", "NE 6th St"},
        {"S12", "NE 12th St"},
        {"S20", "NE 20th St"}
      ])

    route = route(organization, version, first, middle, last)

    %{
      organization: organization,
      version: version,
      actor: actor,
      route: route,
      first: first,
      middle: middle,
      last: last,
      audit: audit_context(organization, version, actor)
    }
  end

  describe "the scripts the question offers" do
    setup :editor_conn

    test "a detour's own scripts come first, and choosing one fills the text from the facts",
         context do
      alert = detour_alert(context)
      {:ok, view, _html} = live(context.conn, message_path(context, alert))

      # Arriving with wording of nobody's own generates what a script would
      # produce, so the reader starts from a sentence rather than from a blank
      # form (AC-22).
      assert {:ok, saved} = Alerts.get_alert(context.audit, alert.id)
      assert saved.message.header == @detour_header
      assert saved.message.description == @detour_description
      assert saved.message.customized == false
      assert saved.message.script_key == "builtin:detour"
      assert has_element?(view, "#message-origin", "Detour, stops skipped")
      assert view |> element("#message-header") |> render() =~ @detour_header

      view |> element("#browse-scripts") |> render_click()

      assert has_element?(view, "#message-scripts")
      assert has_element?(view, "#message-scripts-matching", "Scripts for detour")

      # The scripts for this alert's own situation, and only those, are listed
      # as the matches; the rest sit behind a disclosure.
      assert script_names(view, "#message-scripts-list") == ["Detour, stops skipped"]

      others = script_names(view, "#message-scripts-other-list")

      assert length(others) == 7
      assert "Delays" in others
      assert "Service suspended" in others

      view |> element("#message-script-0") |> render_click()

      assert {:ok, chosen} = Alerts.get_alert(context.audit, alert.id)
      assert chosen.message.header == @detour_header
      assert chosen.message.description == @detour_description
      assert chosen.message.customized == false
      assert chosen.message.script_key == "builtin:detour"
      refute has_element?(view, "#message-scripts")
    end

    test "a script the chooser never offered stores nothing", context do
      alert = detour_alert(context)
      {:ok, view, _html} = live(context.conn, message_path(context, alert))

      revision = revision(context, alert)

      # Sent as a raw event rather than through `element/2`: this is what a
      # hand-made event would carry, and it names a key no card offered.
      render_click(view, "choose_script", %{"key" => "builtin:no_service_day"})

      assert {:ok, unchanged} = Alerts.get_alert(context.audit, alert.id)
      assert unchanged.revision == revision
      assert unchanged.message.header == @detour_header
    end

    test "an organization's own script is offered beside the built-ins", context do
      {:ok, _script} =
        Alerts.create_script(context.audit, %{
          "name" => "Route detour",
          "situation" => "detour",
          "header_template" => "Route [route] detour: [stop] not served",
          "description_template" => "Board at [alternate stop] instead."
        })

      alert = detour_alert(context)
      {:ok, view, _html} = live(context.conn, message_path(context, alert))

      view |> element("#browse-scripts") |> render_click()

      # Both detour scripts are matches, and the organization's comes first
      # because `Alerts.list_scripts/1` lists organization scripts before
      # built-ins.
      assert script_names(view, "#message-scripts-list") == [
               "Route detour",
               "Detour, stops skipped"
             ]

      view |> element("#message-script-0") |> render_click()

      assert {:ok, saved} = Alerts.get_alert(context.audit, alert.id)
      assert saved.message.script_key =~ "org:"
      assert saved.message.header == "Route 1 detour: NE 6th St not served"
    end
  end

  describe "wording the operator wrote" do
    setup :editor_conn

    test "editing the header marks it customized, and a later fact change asks about it",
         context do
      alert = detour_alert(context)
      {:ok, view, _html} = live(context.conn, message_path(context, alert))

      render_change(view, "autosave", %{
        "alert" => %{"message" => %{"header" => "Route 1 detour overnight"}}
      })

      assert {:ok, saved} = Alerts.get_alert(context.audit, alert.id)
      assert saved.message.header == "Route 1 detour overnight"
      assert saved.message.customized == true

      # The answers change under the wording: the stretch it skips is a
      # different one, which changes the stop facts the text was generated from.
      render_patch(view, stops_path(context, alert))
      assert has_element?(view, "#alert-stops-list")

      view |> element("#alert-stop-#{context.middle.id}") |> render_click()
      view |> element("#alert-stop-#{context.first.id}") |> render_click()

      render_patch(view, message_path(context, alert))

      # The wording is still the operator's, and the change is reported rather
      # than applied (FH-22).
      assert {:ok, after_change} = Alerts.get_alert(context.audit, alert.id)
      assert after_change.message.header == "Route 1 detour overnight"
      assert after_change.message.customized == true
      assert has_element?(view, "#review-wording")
      assert has_element?(view, "#use-generated-text")
      assert has_element?(view, "#confirm-wording")
    end

    test "#use-generated-text replaces the text with the regenerated version", context do
      alert = detour_alert(context)
      {:ok, view, _html} = live(context.conn, message_path(context, alert))

      render_change(view, "autosave", %{
        "alert" => %{"message" => %{"header" => "Route 1 detour overnight"}}
      })

      render_patch(view, stops_path(context, alert))
      view |> element("#alert-stop-#{context.middle.id}") |> render_click()
      view |> element("#alert-stop-#{context.first.id}") |> render_click()
      render_patch(view, message_path(context, alert))

      assert has_element?(view, "#review-wording")

      view |> element("#use-generated-text") |> render_click()

      # The regenerated text is filled from the answers as they stand now, and
      # the row is no longer marked customized, so there is nothing left to
      # review.
      assert {:ok, regenerated} = Alerts.get_alert(context.audit, alert.id)

      assert regenerated.message.header ==
               "Route 1 detour: NE 20th St to NE 12th St not served"

      assert regenerated.message.description ==
               "Mon–Fri, 8 PM to 5 AM the next day, Oct 5 to Oct 23, " <>
                 "Route 1 buses to Lincoln City are detoured because of roadwork. " <>
                 "Stops from NE 20th St to NE 12th St are not served."

      assert regenerated.message.customized == false
      refute has_element?(view, "#review-wording")
    end

    test "saying the wording was checked keeps it and records the acknowledgement", context do
      alert = detour_alert(context)
      {:ok, view, _html} = live(context.conn, message_path(context, alert))

      render_change(view, "autosave", %{
        "alert" => %{"message" => %{"header" => "Route 1 detour overnight"}}
      })

      render_patch(view, stops_path(context, alert))
      view |> element("#alert-stop-#{context.first.id}") |> render_click()
      render_patch(view, message_path(context, alert))

      assert has_element?(view, "#review-wording")

      view |> element("#confirm-wording") |> render_click()

      # The acknowledgement moves the stored digest to the current facts and
      # leaves the words alone.
      assert {:ok, checked} = Alerts.get_alert(context.audit, alert.id)
      assert checked.message.header == "Route 1 detour overnight"
      assert checked.message.customized == true
      refute has_element?(view, "#review-wording")

      # A later change asks again rather than being answered once for all.
      render_patch(view, stops_path(context, alert))
      view |> element("#alert-stop-#{context.middle.id}") |> render_click()
      render_patch(view, message_path(context, alert))

      assert has_element?(view, "#review-wording")
    end

    test "arriving again never regenerates wording the operator wrote", context do
      alert = detour_alert(context)
      {:ok, view, _html} = live(context.conn, message_path(context, alert))

      render_change(view, "autosave", %{
        "alert" => %{"message" => %{"header" => "Route 1 detour overnight"}}
      })

      # A full reload of the row, with the same answers as before: nothing has
      # changed, so nothing is regenerated and the wording survives the page.
      {:ok, reloaded, _html} = live(context.conn, message_path(context, alert))

      assert {:ok, saved} = Alerts.get_alert(context.audit, alert.id)
      assert saved.message.header == "Route 1 detour overnight"
      assert reloaded |> element("#message-header") |> render() =~ "Route 1 detour overnight"
      refute has_element?(reloaded, "#review-wording")
    end
  end

  describe "the advisory checks" do
    setup :editor_conn

    test "a header over 60 characters is advised about and still saves", context do
      alert = detour_alert(context)
      {:ok, view, _html} = live(context.conn, message_path(context, alert))

      header = String.duplicate("a", 61)

      render_change(view, "autosave", %{"alert" => %{"message" => %{"header" => header}}})

      # The advisory is reported in the words AC-12 fixes...
      assert has_element?(
               view,
               "#message-check-short",
               "Short message is 61 characters. Apps may cut it off after about 60."
             )

      # ...and nothing refuses the write: the row holds what was typed, the save
      # bar says the write landed, and the checks are advisory (AC-12, AC-22).
      assert {:ok, saved} = Alerts.get_alert(context.audit, alert.id)
      assert saved.message.header == header
      assert has_element?(view, "#alert-save-status", "Saved")

      view |> element("#alert-message-continue") |> render_click()

      # A header the advisory complains about is not a reason to stop: the
      # editor carries the reader on to the review.
      assert has_element?(view, "#alert-question-title", "Review alert")
      assert {:ok, still} = Alerts.get_alert(context.audit, alert.id)
      assert still.message.header == header
    end

    test "the checks report the description's missing timing without blocking", context do
      alert = delay_alert(context)
      {:ok, view, _html} = live(context.conn, message_path(context, alert))

      # The delay script asks for the minutes, and this alert has none, so the
      # header names the fact it could not fill rather than claiming a number.
      assert has_element?(view, "#message-check-when", "No when answer to check yet.")
      assert view |> element("#message-header") |> render() =~ "[minutes]"
    end

    test "markup in the wording is advised about and the text is kept as typed", context do
      alert = detour_alert(context)
      {:ok, view, _html} = live(context.conn, message_path(context, alert))

      render_change(view, "autosave", %{
        "alert" => %{"message" => %{"header" => "Route 1 <b>detour</b>"}}
      })

      assert has_element?(
               view,
               "#message-check-plain_text",
               "Remove < and >. Rider messages are plain text and apps show those characters."
             )

      assert {:ok, saved} = Alerts.get_alert(context.audit, alert.id)
      assert saved.message.header == "Route 1 <b>detour</b>"
    end
  end

  describe "the guidelines panel" do
    setup :editor_conn

    test "the recommended guidelines are shown until the organization stores its own",
         context do
      alert = detour_alert(context)
      {:ok, view, _html} = live(context.conn, message_path(context, alert))

      assert has_element?(view, "#message-guidelines")
      assert has_element?(view, "#message-guidelines-body", "Aim for 60 characters or fewer")

      {:ok, _settings} =
        Alerts.save_guidelines(context.audit, "Start with the route and the change.", 0)

      {:ok, reloaded, _html} = live(context.conn, message_path(context, alert))

      assert has_element?(
               reloaded,
               "#message-guidelines-body",
               "Start with the route and the change."
             )

      refute has_element?(reloaded, "#message-guidelines-body", "Aim for 60 characters or fewer")
    end
  end

  # -- Fixtures ------------------------------------------------------------

  # A planned weekly detour: the situation with scripts of its own, two skipped
  # stops, roadwork, and a Monday-to-Friday 8 PM to 5 AM run.
  defp detour_alert(context) do
    alert_fixture(context.audit, %{
      "urgency" => "planned",
      "situation" => "detour",
      "cause" => "construction",
      "scope" => %{
        "shape" => "route_stops",
        "route_ids" => [context.route.id],
        "stop_ids" => [context.first.id, context.last.id],
        "direction_id" => 0
      },
      "timing" => %{
        "pattern" => "weekly",
        "first_date" => "2026-10-05",
        "weeks" => 3,
        "weekdays" => [1, 2, 3, 4, 5],
        "start_time" => "20:00:00",
        "end_time" => "05:00:00"
      }
    })
  end

  # A delay with no minutes and no timing, so the facts a delay script fills are
  # the ones this alert is missing.
  defp delay_alert(context) do
    alert_fixture(context.audit, %{
      "urgency" => "now",
      "situation" => "delay",
      "scope" => %{"shape" => "routes", "route_ids" => [context.route.id]}
    })
  end

  defp stops(organization, version, rows) do
    rows
    |> Enum.map(fn {stop_id, stop_name} ->
      {:ok, stop} =
        Gtfs.create_stop(%{
          organization_id: organization.id,
          gtfs_version_id: version.id,
          stop_id: stop_id,
          stop_name: stop_name,
          location_type: 0,
          stop_lat: Decimal.new("44.6210"),
          stop_lon: Decimal.new("-124.0490")
        })

      stop
    end)
    |> case do
      [first, middle, last] -> %{first: first, middle: middle, last: last}
    end
  end

  # One route with the three stops in riders' order, its own direction named by
  # destination, and one trip - which is what puts the stops in the skipped-stop
  # question's list and the destination in the message's `[direction]`.
  defp route(organization, version, first, middle, last) do
    {:ok, route} =
      Gtfs.create_route(%{
        organization_id: organization.id,
        gtfs_version_id: version.id,
        route_id: "R1",
        route_short_name: "Route 1",
        route_long_name: "Coast Highway",
        route_type: 3
      })

    bundle =
      schedule_pattern_fixture(organization.id, version.id, %{
        route_id: "R1",
        direction_id: 0,
        headsign: "Lincoln City",
        stops: Enum.map([first, middle, last], &{&1.stop_id, 0, 0, 0})
      })

    service = calendar_fixture(organization.id, version.id)

    schedule_trip_fixture(organization.id, version.id, "R1", bundle, %{
      service_id: service.service_id,
      trip_id: "T-R1"
    })

    route
  end

  defp editor_conn(context) do
    %{
      context
      | conn: log_in_user(build_conn(), context.actor, organization: context.organization)
    }
  end

  defp message_path(context, alert),
    do: "/gtfs/#{context.version.id}/alerts/#{alert.id}?step=message"

  defp stops_path(context, alert),
    do: "/gtfs/#{context.version.id}/alerts/#{alert.id}?step=stops"

  # The names the script list shows, read from the list itself rather than from
  # `Alerts.list_scripts/1`, so the ordering the reader sees is the ordering
  # asserted here.
  defp script_names(view, selector) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(selector <> " li span.font-bold")
    |> Enum.map(&LazyHTML.text/1)
  end

  defp revision(context, alert) do
    {:ok, saved} = Alerts.get_alert(context.audit, alert.id)
    saved.revision
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
