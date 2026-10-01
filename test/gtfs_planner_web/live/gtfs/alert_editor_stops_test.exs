defmodule GtfsPlannerWeb.Gtfs.AlertEditorStopsTest do
  @moduledoc """
  Step 17: a stop target is a selection, never typed text (AC-18, CL-18).

  Every expectation is a literal from the specification's stop-question rules
  (spec AC-18, R7, R1) or from the fixture's own stop and route names, never a
  value recomputed by the module under test. The ids are the ones the templates
  give each control, the situations are `GtfsPlanner.Alerts.Alert`'s own, and
  the shared-stop question is the prototype's sentence about the fixture's own
  two routes.
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

  setup do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id, %{name: "Fall 2026 service"})
    other_version = gtfs_version_fixture(organization.id, %{name: "Spring 2026 service"})
    actor = editor_fixture(organization)
    agency_fixture(organization.id, version.id, %{agency_timezone: "America/Los_Angeles"})
    agency_fixture(organization.id, other_version.id, %{agency_timezone: "America/Los_Angeles"})

    %{
      organization: organization,
      version: version,
      other_version: other_version,
      actor: actor,
      audit: audit_context(organization, version, actor)
    }
  end

  describe "the place question" do
    setup :editor_conn

    test "a chosen stop is stored by its row UUID and names the routes that serve it", context do
      %{depot: depot} = stops(context)
      _route_1 = pattern(context, "R1", [{"S_DEPOT", 0}, {"S_HARBOR", 600}])
      _route_12 = pattern(context, "R12", [{"S_DEPOT", 0}, {"S_NYE", 600}])

      alert = alert_with(context, %{"urgency" => "now", "situation" => "stop_moved"})

      {:ok, view, _html} =
        live(context.conn, edit_path(context.version, alert) <> "?step=place")

      assert has_element?(view, "#alert-question-title", "Which stop or station?")
      assert has_element?(view, "#alert-place-stop")

      # The place question's form carries only the base revision and the
      # combobox, so that is the payload the browser sends: no `alert[scope]`.
      view
      |> render_change("autosave", %{
        "alert" => %{"revision" => Integer.to_string(alert.revision)},
        "place" => %{"stop_id" => depot.id}
      })

      assert {:ok, saved} = Alerts.get_alert(context.audit, alert.id)
      assert saved.scope.stop_ids == [depot.id]
      assert saved.scope.shape == :stop_all_routes

      # The routes that call at the chosen place are preselected, so the routes
      # question lists what the place actually has.
      serving = Alerts.routes_at_stops(context.audit, [depot.id])
      assert Enum.sort(saved.scope.route_ids) == Enum.sort(Enum.map(serving, & &1.id))
      assert length(serving) == 2

      # The widget's own field holds the chosen identity, and the summary says
      # the place by name rather than by what was searched for.
      assert has_element?(view, "input#place_stop_id[value='#{depot.id}']")
      assert render(view) =~ depot.stop_name
    end

    test "typed text alone never becomes a stop", context do
      %{depot: depot} = stops(context)
      _route = pattern(context, "R1", [{"S_DEPOT", 0}])

      # No place has been chosen, which is the case R7 names: text typed into
      # the combobox is a search, so it stores no stop.
      alert =
        alert_with(context, %{
          "urgency" => "now",
          "situation" => "stop_moved",
          "scope" => %{"shape" => "stop_all_routes"}
        })

      {:ok, view, _html} =
        live(context.conn, edit_path(context.version, alert) <> "?step=place")

      revision = alert.revision

      render_change(view, "live_select_change", %{
        "id" => "alert-place-stop",
        "text" => depot.stop_name
      })

      assert {:ok, unchanged} = Alerts.get_alert(context.audit, alert.id)
      assert unchanged.scope.stop_ids == nil
      assert unchanged.scope.shape == :stop_all_routes
      assert unchanged.revision == revision
    end

    test "typing over a chosen label clears the identity it belonged to", context do
      %{depot: depot} = stops(context)
      _route = pattern(context, "R1", [{"S_DEPOT", 0}])

      alert =
        alert_with(context, %{
          "urgency" => "now",
          "situation" => "stop_moved",
          "scope" => %{"shape" => "stop_all_routes", "stop_ids" => [depot.id]}
        })

      {:ok, view, _html} =
        live(context.conn, edit_path(context.version, alert) <> "?step=place")

      # The label the stop renders is not what the editor just typed, so the
      # identity is dropped rather than left attached to new text (R7, PM-9).
      render_change(view, "live_select_change", %{
        "id" => "alert-place-stop",
        "text" => "Newport Transit Center"
      })

      assert {:ok, saved} = Alerts.get_alert(context.audit, alert.id)
      assert saved.scope.stop_ids == []
      assert has_element?(view, "#alert-place-stop")
    end

    test "a forged selection for another version's stop saves nothing", context do
      %{coast: coast} = stops(context)
      other = other_version_stop(context.other_version, "S_OTHER", "Somewhere Else")

      _route = pattern(context, "R1", [{"S_COAST", 0}])

      alert = alert_with(context, %{"urgency" => "now", "situation" => "stop_moved"})

      {:ok, view, _html} =
        live(context.conn, edit_path(context.version, alert) <> "?step=place")

      revision = alert.revision

      view |> render_change("autosave", %{"place" => %{"stop_id" => other.id}})
      view |> render_change("autosave", %{"place" => %{"stop_id" => coast.id}})

      # The stop of the sibling version is not in this version's lookup, so it
      # stored nothing; the stop of this version did (R1, CR-4).
      assert {:ok, saved} = Alerts.get_alert(context.audit, alert.id)
      assert saved.scope.stop_ids == [coast.id]
      assert saved.revision == revision + 1
    end

    test "Continue carries a chosen place on to the routes question", context do
      %{depot: depot} = stops(context)
      _route_1 = pattern(context, "R1", [{"S_DEPOT", 0}])

      alert = alert_with(context, %{"urgency" => "now", "situation" => "stop_moved"})

      {:ok, view, _html} =
        live(context.conn, edit_path(context.version, alert) <> "?step=place")

      assert has_element?(view, "#alert-place-continue")

      view |> render_change("autosave", %{"place" => %{"stop_id" => depot.id}})
      view |> element("#alert-place-continue") |> render_click()

      # The place preselects the routes that call at it, so the reader arrives
      # at the routes question with something already pressed (AC-18).
      assert has_element?(view, "#alert-question-title", "Which routes are affected?")
      assert {:ok, saved} = Alerts.get_alert(context.audit, alert.id)
      assert saved.scope.stop_ids == [depot.id]
    end

    test "Continue with no place chosen says so and writes nothing", context do
      _named_stops = stops(context)

      alert = alert_with(context, %{"urgency" => "now", "situation" => "stop_moved"})

      {:ok, view, _html} =
        live(context.conn, edit_path(context.version, alert) <> "?step=place")

      revision = alert.revision

      view |> element("#alert-place-continue") |> render_click()

      assert has_element?(view, "#alert-place-error", "Choose the place")
      assert has_element?(view, "#alert-question-title", "Which stop or station?")
      assert {:ok, unchanged} = Alerts.get_alert(context.audit, alert.id)
      assert unchanged.revision == revision
    end

    test "a combobox the editor does not render is refused", context do
      _named_stops = stops(context)
      alert = alert_with(context, %{"urgency" => "now", "situation" => "stop_moved"})

      {:ok, view, _html} =
        live(context.conn, edit_path(context.version, alert) <> "?step=place")

      revision = alert.revision

      render_change(view, "live_select_change", %{
        "id" => "alert-somewhere-else",
        "text" => "Depot"
      })

      assert {:ok, unchanged} = Alerts.get_alert(context.audit, alert.id)
      assert unchanged.revision == revision
    end
  end

  describe "the skipped-stops question" do
    setup :editor_conn

    test "each toggle is saved as it is made and Continue carries them on", context do
      %{coast: coast, depot: depot, harbor: harbor} = stops(context)
      coast_route = pattern(context, "R1", [{"S_COAST", 0}, {"S_DEPOT", 600}, {"S_HARBOR", 1200}])
      # A second route calls at Harbor Street, which is what makes the shared
      # question the next one once that stop is chosen.
      _other_route = pattern(context, "R12", [{"S_HARBOR", 0}, {"S_NYE", 600}])

      alert = detour_alert(context, coast_route.id)

      {:ok, view, _html} =
        live(context.conn, edit_path(context.version, alert) <> "?step=stops")

      # The list is the chosen route's own stops, in the order riders meet them.
      assert has_element?(view, "#alert-question-title", "Which stops will buses skip?")
      assert has_element?(view, "#alert-stop-#{coast.id}", "Newport Transit Center")
      assert has_element?(view, "#alert-stop-#{depot.id}", "Depot Street")
      assert has_element?(view, "#alert-stop-#{harbor.id}", "Harbor Street")

      view |> element("#alert-stop-#{harbor.id}") |> render_click()

      assert {:ok, saved} = Alerts.get_alert(context.audit, alert.id)
      assert saved.scope.stop_ids == [harbor.id]
      assert has_element?(view, "#alert-stop-#{harbor.id}[aria-pressed='true']")

      view |> element("#alert-stops-continue") |> render_click()

      assert has_element?(
               view,
               "#alert-question-title",
               "Are other routes affected at these stops?"
             )

      assert {:ok, saved} = Alerts.get_alert(context.audit, alert.id)
      assert saved.scope.stop_ids == [harbor.id]
    end

    test "Continue with nothing chosen says so and writes nothing", context do
      %{coast: _coast} = stops(context)
      coast_route = pattern(context, "R1", [{"S_COAST", 0}])
      alert = detour_alert(context, coast_route.id)

      {:ok, view, _html} =
        live(context.conn, edit_path(context.version, alert) <> "?step=stops")

      revision = alert.revision

      view |> element("#alert-stops-continue") |> render_click()

      assert has_element?(view, "#alert-stops-error", "at least one stop")
      assert has_element?(view, "#alert-question-title", "Which stops will buses skip?")
      assert {:ok, unchanged} = Alerts.get_alert(context.audit, alert.id)
      assert unchanged.revision == revision
    end

    test "a stretch resolves to the stops between the two ends, in route order", context do
      %{depot: depot, harbor: harbor} = stops(context)
      coast_route = pattern(context, "R1", [{"S_COAST", 0}, {"S_DEPOT", 600}, {"S_HARBOR", 1200}])

      alert = detour_alert(context, coast_route.id)

      {:ok, view, _html} =
        live(context.conn, edit_path(context.version, alert) <> "?step=stops")

      # The two selects are fields of the autosave form, so a change carries the
      # whole form the way the browser sends it. One end alone stores nothing.
      view
      |> form("#alert-form", %{"stretch" => %{"from" => depot.id}})
      |> render_change()

      assert {:ok, unchanged} = Alerts.get_alert(context.audit, alert.id)
      assert unchanged.scope.stretch_from_stop_id == nil
      assert unchanged.revision == alert.revision

      view
      |> form("#alert-form", %{"stretch" => %{"from" => depot.id, "to" => harbor.id}})
      |> render_change()

      assert {:ok, saved} = Alerts.get_alert(context.audit, alert.id)
      assert saved.scope.stretch_from_stop_id == depot.id
      assert saved.scope.stretch_to_stop_id == harbor.id
      assert saved.scope.stop_ids == [depot.id, harbor.id]
      refute saved.scope.stop_ids == [harbor.id, depot.id]
      assert saved.scope.shape == :route_stops
    end

    test "a stretch between stops of two different routes resolves nothing", context do
      %{coast: coast, nye: nye} = stops(context)
      coast_route = pattern(context, "R1", [{"S_COAST", 0}, {"S_DEPOT", 600}])
      nye_route = pattern(context, "R12", [{"S_NYE", 0}, {"S_HARBOR", 600}])

      alert =
        alert_with(context, %{
          "urgency" => "now",
          "situation" => "detour",
          "scope" => %{"shape" => "routes", "route_ids" => [coast_route.id, nye_route.id]}
        })

      {:ok, view, _html} =
        live(context.conn, edit_path(context.version, alert) <> "?step=stops")

      # The union of the two routes' stops lists both ends, but no one route
      # runs from one to the other, so there is no stretch to skip.
      view
      |> form("#alert-form", %{"stretch" => %{"from" => coast.id, "to" => nye.id}})
      |> render_change()

      assert has_element?(view, "#alert-stops-error", "same route")
      assert {:ok, unchanged} = Alerts.get_alert(context.audit, alert.id)
      assert unchanged.scope.stop_ids == nil
      assert unchanged.revision == alert.revision
    end

    test "all stops still served changes the situation to a delay", context do
      %{harbor: _harbor} = stops(context)
      coast_route = pattern(context, "R1", [{"S_HARBOR", 0}])
      alert = detour_alert(context, coast_route.id)

      {:ok, view, _html} =
        live(context.conn, edit_path(context.version, alert) <> "?step=stops")

      view |> element("#all-stops-served") |> render_click()

      assert {:ok, saved} = Alerts.get_alert(context.audit, alert.id)
      assert saved.situation == :delay
      assert saved.scope.stop_ids == []
    end
  end

  describe "all stops still served after another editor saved" do
    setup :editor_conn

    test "shows the conflict instead of changing the situation", context do
      %{harbor: _harbor} = stops(context)
      coast_route = pattern(context, "R1", [{"S_HARBOR", 0}])
      alert = detour_alert(context, coast_route.id)

      {:ok, view, _html} =
        live(context.conn, edit_path(context.version, alert) <> "?step=stops")

      assert {:ok, _other} =
               Alerts.save_draft(context.audit, alert.id, alert.revision, %{"cause" => "weather"})

      view |> element("#all-stops-served") |> render_click()

      assert has_element?(view, "#alert-conflict")
      assert has_element?(view, "#conflict-save-new")

      assert {:ok, row} = Alerts.get_alert(context.audit, alert.id)
      assert row.situation == :detour
      assert row.cause == :weather
    end
  end

  describe "the shared-stop question" do
    setup :editor_conn

    test "a stop another route also serves asks about that route by name", context do
      %{depot: depot} = stops(context)
      coast_route = pattern(context, "R1", [{"S_COAST", 0}, {"S_DEPOT", 600}])
      _other_route = pattern(context, "R12", [{"S_DEPOT", 0}, {"S_NYE", 600}])

      alert =
        alert_with(context, %{
          "urgency" => "now",
          "situation" => "detour",
          "scope" => %{
            "shape" => "route_stops",
            "route_ids" => [coast_route.id],
            "stop_ids" => [depot.id]
          }
        })

      {:ok, view, _html} =
        live(context.conn, edit_path(context.version, alert) <> "?step=shared")

      other =
        Alerts.routes_at_stops(context.audit, [depot.id]) |> Enum.find(&(&1.id != coast_route.id))

      assert other != nil

      assert has_element?(
               view,
               "#alert-shared-#{other.id}",
               "#{other.label} also stops at Depot Street"
             )

      assert has_element?(view, "#alert-shared-#{other.id}-yes")
      assert has_element?(view, "#alert-shared-#{other.id}-no")

      # The question is the one the step sequence only shows when a stop the
      # alert names is served by a route it does not (INV-2).
      assert has_element?(view, "#alert-step-shared[aria-current='step']")
    end

    test "saying yes stores the pairs that make the other route affected there too", context do
      %{depot: depot} = stops(context)
      coast_route = pattern(context, "R1", [{"S_COAST", 0}, {"S_DEPOT", 600}])
      _other_route = pattern(context, "R12", [{"S_DEPOT", 0}, {"S_NYE", 600}])

      alert =
        alert_with(context, %{
          "urgency" => "now",
          "situation" => "detour",
          "scope" => %{
            "shape" => "route_stops",
            "route_ids" => [coast_route.id],
            "stop_ids" => [depot.id]
          }
        })

      other =
        Alerts.routes_at_stops(context.audit, [depot.id]) |> Enum.find(&(&1.id != coast_route.id))

      {:ok, view, _html} =
        live(context.conn, edit_path(context.version, alert) <> "?step=shared")

      render_click(view, "choose_shared", %{"answer" => "yes"})

      assert {:ok, saved} = Alerts.get_alert(context.audit, alert.id)
      assert saved.scope.all_routes_at_stops == true
      assert [%{route_id: route_id, stop_id: stop_id}] = saved.scope.route_stop_pairs
      assert route_id == other.id
      assert stop_id == depot.id

      # The answer advanced to the next question this alert asks.
      assert has_element?(view, "#alert-question-title", "Where should riders board instead?")
    end

    test "saying no stores that the other route is not affected", context do
      %{depot: depot} = stops(context)
      coast_route = pattern(context, "R1", [{"S_COAST", 0}, {"S_DEPOT", 600}])
      _other_route = pattern(context, "R12", [{"S_DEPOT", 0}, {"S_NYE", 600}])

      alert =
        alert_with(context, %{
          "urgency" => "now",
          "situation" => "detour",
          "scope" => %{
            "shape" => "route_stops",
            "route_ids" => [coast_route.id],
            "stop_ids" => [depot.id]
          }
        })

      {:ok, view, _html} =
        live(context.conn, edit_path(context.version, alert) <> "?step=shared")

      render_click(view, "choose_shared", %{"answer" => "no"})

      assert {:ok, saved} = Alerts.get_alert(context.audit, alert.id)
      assert saved.scope.all_routes_at_stops == false
      assert saved.scope.route_stop_pairs == []
    end

    test "saying no after yes drops the pairs the yes stored", context do
      %{depot: depot} = stops(context)
      coast_route = pattern(context, "R1", [{"S_COAST", 0}, {"S_DEPOT", 600}])
      _other_route = pattern(context, "R12", [{"S_DEPOT", 0}, {"S_NYE", 600}])

      alert =
        alert_with(context, %{
          "urgency" => "now",
          "situation" => "detour",
          "scope" => %{
            "shape" => "route_stops",
            "route_ids" => [coast_route.id],
            "stop_ids" => [depot.id]
          }
        })

      {:ok, view, _html} =
        live(context.conn, edit_path(context.version, alert) <> "?step=shared")

      render_click(view, "choose_shared", %{"answer" => "yes"})

      assert {:ok, answered_yes} = Alerts.get_alert(context.audit, alert.id)
      assert [_pair] = answered_yes.scope.route_stop_pairs

      render_click(view, "choose_shared", %{"answer" => "no"})

      assert {:ok, answered_no} = Alerts.get_alert(context.audit, alert.id)
      assert answered_no.scope.all_routes_at_stops == false
      assert answered_no.scope.route_stop_pairs == []
    end

    test "no unchosen route at the stops means the question is not asked", context do
      %{coast: coast} = stops(context)
      coast_route = pattern(context, "R1", [{"S_COAST", 0}])

      alert =
        alert_with(context, %{
          "urgency" => "now",
          "situation" => "detour",
          "scope" => %{
            "shape" => "route_stops",
            "route_ids" => [coast_route.id],
            "stop_ids" => [coast.id]
          }
        })

      {:ok, view, _html} = live(context.conn, edit_path(context.version, alert) <> "?step=stops")

      # `steps_for/2` leaves `shared` out entirely, so the URL falls back to the
      # first question this alert asks rather than rendering an empty card.
      assert has_element?(view, "#alert-question-title", "Which stops will buses skip?")
      refute has_element?(view, "#alert-step-shared")
    end
  end

  describe "the boarding alternative" do
    setup :editor_conn

    test "the search leaves out the affected stops and lists the chosen routes' stops first",
         context do
      %{depot: depot, harbor: harbor} = stops(context)
      elm = stop(context, "S_ELM", "Elm Street", "1200")

      coast_route =
        pattern(context, "R1", [{"S_COAST", 0}, {"S_DEPOT", 600}, {"S_HARBOR", 1200}])

      alert =
        alert_with(context, %{
          "urgency" => "now",
          "situation" => "detour",
          "scope" => %{
            "shape" => "route_stops",
            "route_ids" => [coast_route.id],
            "stop_ids" => [depot.id]
          }
        })

      {:ok, view, _html} =
        live(context.conn, edit_path(context.version, alert) <> "?step=alternative")

      assert has_element?(view, "#alert-question-title", "Where should riders board instead?")
      assert has_element?(view, "#alert-boarding-stop")

      # Typing in the boarding combobox searches through the editor's own call:
      # the affected stop is not offered to itself, and a stop of the route the
      # alert names precedes one that is not, though "Elm" sorts first by name.
      view |> element("#alternative_stop_id_text_input") |> render_focus()

      render_hook(view, "live_select_change", %{
        "id" => "alert-boarding-stop",
        "text" => "Street"
      })

      options =
        view
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("#alert-boarding-stop ul li")
        |> Enum.map(&LazyHTML.text/1)

      assert length(options) == 2
      refute Enum.any?(options, &(&1 =~ depot.stop_name))
      assert [first, second] = options
      assert first =~ harbor.stop_name
      assert second =~ elm.stop_name
    end

    test "choosing a stop stores its UUID and clears written directions", context do
      %{coast: coast, depot: depot, harbor: harbor} = stops(context)

      _coast_route =
        pattern(context, "R1", [{"S_COAST", 0}, {"S_DEPOT", 600}, {"S_HARBOR", 1200}])

      alert =
        alert_with(context, %{
          "urgency" => "now",
          "situation" => "stop_moved",
          "scope" => %{
            "shape" => "stop_all_routes",
            "stop_ids" => [depot.id],
            "alternative_directions" => "Board on the corner."
          }
        })

      {:ok, view, _html} =
        live(context.conn, edit_path(context.version, alert) <> "?step=alternative")

      # The boarding question's form carries the base revision and the combobox
      # alone while "Write directions instead" is closed.
      view
      |> render_change("autosave", %{
        "alert" => %{"revision" => Integer.to_string(alert.revision)},
        "alternative" => %{"stop_id" => harbor.id}
      })

      assert {:ok, saved} = Alerts.get_alert(context.audit, alert.id)
      assert saved.scope.alternative_stop_id == harbor.id
      assert saved.scope.alternative_directions == nil
      _ = coast
    end

    test "write directions saves the text and clears the chosen stop", context do
      %{depot: depot, harbor: harbor} = stops(context)
      _coast_route = pattern(context, "R1", [{"S_DEPOT", 0}, {"S_HARBOR", 600}])

      alert =
        alert_with(context, %{
          "urgency" => "now",
          "situation" => "stop_moved",
          "scope" => %{"shape" => "stop_all_routes", "stop_ids" => [depot.id]}
        })

      {:ok, view, _html} =
        live(context.conn, edit_path(context.version, alert) <> "?step=alternative")

      view |> render_change("autosave", %{"alternative" => %{"stop_id" => harbor.id}})

      view |> element("#write-directions") |> render_click()

      assert {:ok, cleared} = Alerts.get_alert(context.audit, alert.id)
      assert cleared.scope.alternative_stop_id == nil

      view
      |> render_change("autosave", %{
        "alert" => %{
          "scope" => %{"alternative_directions" => "Board at the temporary stop on NE Main St."}
        }
      })

      assert {:ok, saved} = Alerts.get_alert(context.audit, alert.id)
      assert saved.scope.alternative_directions == "Board at the temporary stop on NE Main St."
    end

    test "a moved stop cannot advance without a stop or written directions", context do
      %{depot: depot} = stops(context)
      _coast_route = pattern(context, "R1", [{"S_DEPOT", 0}])

      alert =
        alert_with(context, %{
          "urgency" => "now",
          "situation" => "stop_moved",
          "scope" => %{"shape" => "stop_all_routes", "stop_ids" => [depot.id]}
        })

      {:ok, view, _html} =
        live(context.conn, edit_path(context.version, alert) <> "?step=alternative")

      view |> element("#alert-alternative-continue") |> render_click()

      assert has_element?(view, "#alert-alternative-error", "write directions instead")
      assert has_element?(view, "#alert-question-title", "Where should riders board instead?")

      view
      |> render_change("autosave", %{
        "alert" => %{"scope" => %{"alternative_directions" => "Board on the corner."}}
      })

      view |> element("#alert-alternative-continue") |> render_click()

      assert has_element?(view, "#alert-question-title", "When should this alert end?")
    end

    test "an accessibility alert also asks what facility is unavailable", context do
      %{depot: depot} = stops(context)
      _coast_route = pattern(context, "R1", [{"S_DEPOT", 0}])

      alert =
        alert_with(context, %{
          "urgency" => "now",
          "situation" => "accessibility",
          "scope" => %{"shape" => "stop_all_routes", "stop_ids" => [depot.id]}
        })

      {:ok, view, _html} =
        live(context.conn, edit_path(context.version, alert) <> "?step=alternative")

      assert has_element?(view, "input[name='alert[scope][facility]']")

      view
      |> render_change("autosave", %{
        "alert" => %{"scope" => %{"facility" => "North entrance ramp"}}
      })

      assert {:ok, saved} = Alerts.get_alert(context.audit, alert.id)
      assert saved.scope.facility == "North entrance ramp"
    end
  end

  # -- Fixtures ------------------------------------------------------------

  # Three coded stops and one that only another route serves, so the shared-stop
  # question has a real other route to name.
  defp stops(context) do
    %{
      coast: stop(context, "S_COAST", "Newport Transit Center", "1001"),
      depot: stop(context, "S_DEPOT", "Depot Street", "1012"),
      harbor: stop(context, "S_HARBOR", "Harbor Street", "1014"),
      nye: stop(context, "S_NYE", "Nye Beach", "1102")
    }
  end

  defp stop(context, stop_id, stop_name, platform_code) do
    {:ok, stop} =
      insert_stop(%{
        organization_id: context.organization.id,
        gtfs_version_id: context.version.id,
        stop_id: stop_id,
        stop_name: stop_name,
        location_type: 0,
        stop_lat: Decimal.new("44.6210"),
        stop_lon: Decimal.new("-124.0490")
      })

    stop
    |> Ecto.Changeset.change(platform_code: platform_code)
    |> GtfsPlanner.Repo.update!()
  end

  defp other_version_stop(other_version, stop_id, stop_name) do
    {:ok, stop} =
      insert_stop(%{
        organization_id: other_version.organization_id,
        gtfs_version_id: other_version.id,
        stop_id: stop_id,
        stop_name: stop_name,
        location_type: 0,
        stop_lat: Decimal.new("44.0000"),
        stop_lon: Decimal.new("-124.0000")
      })

    stop
  end

  # A route with a pattern over the named stops and one trip, so
  # `Alerts.route_stops/2` and `Alerts.routes_at_stops/2` both have a schedule to
  # read. The pattern's own order is the order the skipped-stop list shows.
  defp pattern(context, route_id, stops) do
    {:ok, route} =
      insert_route(%{
        organization_id: context.organization.id,
        gtfs_version_id: context.version.id,
        route_id: route_id,
        route_short_name: "Route #{route_id}",
        route_long_name: "Route #{route_id}",
        route_type: 3
      })

    bundle =
      schedule_pattern_fixture(context.organization.id, context.version.id, %{
        route_id: route_id,
        direction_id: 0,
        headsign: "To the end of the line",
        stops: Enum.map(stops, fn {stop_id, offset} -> {stop_id, offset, offset, 0} end)
      })

    service = calendar_fixture(context.organization.id, context.version.id)

    schedule_trip_fixture(
      context.organization.id,
      context.version.id,
      route_id,
      bundle,
      %{service_id: service.service_id, trip_id: "T-#{route_id}"}
    )

    route
  end

  defp detour_alert(context, route_id) do
    alert_with(context, %{
      "urgency" => "now",
      "situation" => "detour",
      "scope" => %{"shape" => "routes", "route_ids" => [route_id]}
    })
  end

  defp editor_conn(context) do
    %{
      context
      | conn: log_in_user(build_conn(), context.actor, organization: context.organization)
    }
  end

  defp edit_path(version, alert), do: "/gtfs/#{version.id}/alerts/#{alert.id}"

  defp alert_with(context, attrs), do: alert_fixture(context.audit, attrs)

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
