defmodule GtfsPlannerWeb.Gtfs.AlertEditorReasonTest do
  @moduledoc """
  Step 20: the reason question offers every cause once, keeps **Other reason**
  and **Not known yet** apart, and the other reason's explanation never blocks
  (AC-21, CL-21).

  Every expectation is a literal from the specification - the thirteen GTFS-RT
  causes named in AC-21 and the prototype's own `CAUSES` list, the two words it
  keeps apart, and the explanation it calls optional - and never a value
  recomputed by the module under test. The one reading of the code itself is the
  schema's own enum, checked against that literal list so the cards and the row
  cannot drift apart silently.

  The ids are the ones the templates give each control, so nothing here depends
  on copy or layout.
  """

  use GtfsPlannerWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.AlertsFixtures
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Alerts
  alias GtfsPlanner.Alerts.Alert
  alias GtfsPlanner.Gtfs.AuditContext

  # The prototype's CAUSES list, in its order and with the words a rider reads,
  # paired with the schema's own value for each one.
  @causes [
    {"construction", "Construction or roadwork"},
    {"accident", "Crash"},
    {"weather", "Weather"},
    {"police_activity", "Police activity"},
    {"medical_emergency", "Medical emergency"},
    {"demonstration", "Demonstration"},
    {"special_event", "Special event"},
    {"holiday", "Holiday"},
    {"maintenance", "Maintenance"},
    {"technical_problem", "Vehicle or equipment problem"},
    {"strike", "Strike"},
    {"other_cause", "Other reason"},
    {"unknown_cause", "Not known yet"}
  ]

  setup do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id, %{name: "Fall 2026 service"})
    actor = editor_fixture(organization)
    agency_fixture(organization.id, version.id, %{agency_timezone: "America/Los_Angeles"})

    route =
      route_fixture(organization.id, version.id, %{
        route_id: "R1",
        route_short_name: "Route 1",
        route_long_name: "Coast Highway",
        route_type: 3
      })

    %{
      organization: organization,
      version: version,
      actor: actor,
      route: route,
      audit: audit_context(organization, version, actor)
    }
  end

  describe "the choices the question offers" do
    setup :editor_conn

    test "every cause is offered once, in the prototype's words", context do
      alert = delay_alert(context)
      {:ok, view, html} = live(context.conn, reason_path(alert))

      values = html |> doc() |> LazyHTML.query("#alert-cause button") |> values()

      assert values == Enum.map(@causes, fn {value, _label} -> value end)

      # The schema stores these thirteen and no others, so the cards cannot offer
      # a cause the row would refuse and none can be missing from the row (AC-21).
      assert Enum.sort(values) ==
               Alert |> Ecto.Enum.values(:cause) |> Enum.map(&to_string/1) |> Enum.sort()

      for {value, label} <- @causes do
        assert has_element?(view, "#alert-cause-#{value}")
        assert has_element?(view, "#alert-cause-#{value} span.font-bold", label)
      end
    end

    test "the two open-ended causes are distinct cards with distinct words", context do
      alert = delay_alert(context)
      {:ok, view, _html} = live(context.conn, reason_path(alert))

      # Other and Unknown are separate answers here, so a rider is never asked
      # to mean "other" by a card that says "not known" (FH-21).
      assert has_element?(view, "#alert-cause-other_cause", "Other reason")
      assert has_element?(view, "#alert-cause-unknown_cause", "Not known yet")
      refute has_element?(view, "#alert-cause-other_cause", "Not known yet")
      refute has_element?(view, "#alert-cause-unknown_cause", "Other reason")
    end

    test "the stored cause is the one the reader pressed, and the editor moves on", context do
      alert = delay_alert(context)
      {:ok, view, _html} = live(context.conn, reason_path(alert))

      view |> element("#alert-cause-weather") |> render_click()

      assert {:ok, saved} = Alerts.get_alert(context.audit, alert.id)
      assert saved.cause == :weather
      assert is_nil(saved.cause_detail)

      # A cause is a self-contained answer, so the editor carries the reader on
      # to the next question this alert's own sequence puts after it (INV-2).
      assert has_element?(view, "#alert-question-title", "Check the message for riders")
    end

    test "a cause the question never offered stores nothing", context do
      alert = delay_alert(context)
      {:ok, view, _html} = live(context.conn, reason_path(alert))

      # Sent as a raw event rather than through `form/3`: this is the input a
      # hand-made event would carry, and it names a cause no card offers.
      render_click(view, "choose_cause", %{"cause" => "earthquake"})

      assert {:ok, saved} = Alerts.get_alert(context.audit, alert.id)
      assert is_nil(saved.cause)
      assert saved.revision == alert.revision
      assert has_element?(view, "#alert-reason")
    end
  end

  describe "the other reason's explanation" do
    setup :editor_conn

    test "Other reason reveals the explanation and keeps the reader on the question", context do
      alert = delay_alert(context)
      {:ok, view, _html} = live(context.conn, reason_path(alert))

      refute has_element?(view, "#cause-detail")

      view |> element("#alert-cause-other_cause") |> render_click()

      assert {:ok, saved} = Alerts.get_alert(context.audit, alert.id)
      assert saved.cause == :other_cause
      assert has_element?(view, "#alert-question-title", "Why is this happening?")
      assert has_element?(view, "#alert-cause-other_cause[aria-pressed='true']")
      assert has_element?(view, "#cause-detail")
      assert has_element?(view, "#alert-reason-other label", "Describe the other reason")
    end

    test "the explanation autosaves and is still there after a reload", context do
      alert = delay_alert(context)
      {:ok, view, _html} = live(context.conn, reason_path(alert))

      view |> element("#alert-cause-other_cause") |> render_click()
      render_change(view, "autosave", %{"alert" => %{"cause_detail" => "a fallen tree"}})

      assert {:ok, saved} = Alerts.get_alert(context.audit, alert.id)
      assert saved.cause == :other_cause
      assert saved.cause_detail == "a fallen tree"

      {:ok, reloaded, html} = live(context.conn, reason_path(alert))

      assert has_element?(reloaded, "#cause-detail")
      assert reloaded |> element("#cause-detail") |> render() =~ "a fallen tree"
      assert html =~ "Describe the other reason"
    end

    test "a blank explanation is still a complete answer to the question", context do
      alert = delay_alert(context)
      {:ok, view, _html} = live(context.conn, reason_path(alert))

      view |> element("#alert-cause-other_cause") |> render_click()
      view |> element("#alert-reason-continue") |> render_click()

      # Nothing is refused: the cause is stored and the editor moves on (AC-3).
      assert {:ok, saved} = Alerts.get_alert(context.audit, alert.id)
      assert saved.cause == :other_cause
      assert has_element?(view, "#alert-question-title", "Check the message for riders")
    end

    test "Not known yet hides the explanation and drops what it held", context do
      alert = delay_alert(context)
      {:ok, view, _html} = live(context.conn, reason_path(alert))

      view |> element("#alert-cause-other_cause") |> render_click()
      render_change(view, "autosave", %{"alert" => %{"cause_detail" => "a fallen tree"}})

      view |> element("#alert-cause-unknown_cause") |> render_click()

      assert {:ok, saved} = Alerts.get_alert(context.audit, alert.id)
      assert saved.cause == :unknown_cause

      # The description belonged to the other reason, so it goes with it rather
      # than staying in the rider's message under a different cause.
      assert is_nil(saved.cause_detail)

      {:ok, reloaded, _html} = live(context.conn, reason_path(alert))
      refute has_element?(reloaded, "#cause-detail")
      assert has_element?(reloaded, "#alert-cause-unknown_cause[aria-pressed='true']")
    end

    test "an explanation over the row's own limit is refused and kept on screen", context do
      alert = delay_alert(context)
      {:ok, view, _html} = live(context.conn, reason_path(alert))

      view |> element("#alert-cause-other_cause") |> render_click()

      render_change(view, "autosave", %{
        "alert" => %{"cause_detail" => String.duplicate("a", 201)}
      })

      # The typed text is not thrown away by a refused write (AC-16), and the row
      # keeps the cause the reader chose.
      assert {:ok, saved} = Alerts.get_alert(context.audit, alert.id)
      assert saved.cause == :other_cause
      assert is_nil(saved.cause_detail)
      assert view |> element("#cause-detail") |> render() =~ String.duplicate("a", 201)
    end
  end

  defp delay_alert(context) do
    alert_fixture(context.audit, %{
      "urgency" => "now",
      "situation" => "delay",
      "scope" => %{"shape" => "routes", "route_ids" => [context.route.route_id]}
    })
  end

  defp editor_conn(context) do
    %{
      context
      | conn: log_in_user(build_conn(), context.actor, organization: context.organization)
    }
  end

  defp reason_path(alert),
    do: "/alerts/#{alert.id}?step=reason"

  defp doc(html), do: LazyHTML.from_fragment(html)

  defp values(buttons),
    do: Enum.map(buttons, &List.first(LazyHTML.attribute(&1, "phx-value-cause")))

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
