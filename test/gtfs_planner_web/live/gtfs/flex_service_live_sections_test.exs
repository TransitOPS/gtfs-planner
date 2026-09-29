defmodule GtfsPlannerWeb.Gtfs.FlexServiceLiveSectionsTest do
  @moduledoc """
  Merge evidence (EV-23) for the service page's remaining sections: where riders
  can travel or the bus can detour, who can ride, in exports, and status and
  removal (AC-7, AC-29).

  Each field is judged twice: the page renders it from the draft, and after Save
  the same value is read back from the database through `Flex.get_service/3`.
  The area summaries and the detour zone summary are judged against the real
  `Flex.Geometry` measurements, and the export plan against the R11 IDs the
  export's own builders produce.

  The focused command is deferred to branch review:
  `mix test test/gtfs_planner_web/live/gtfs/flex_service_live_sections_test.exs`.
  """
  use GtfsPlannerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.FlexFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Gtfs.ExportDefaults
  alias GtfsPlanner.Gtfs.Flex
  alias GtfsPlanner.Gtfs.FlexBookingRule

  @distance_options [
    "",
    "200",
    "400",
    "800",
    "1200",
    "1600"
  ]

  @distance_labels [
    "A few blocks (0.2 km)",
    "¼ mile (0.4 km)",
    "½ mile (0.8 km)",
    "¾ mile (1.2 km), most common",
    "1 mile (1.6 km)"
  ]

  describe "where riders can travel" do
    setup :editor_with_flex_version

    test "each area is summarised from the passed geometry and links to the editor", ctx do
      service = area_service(ctx)
      {:ok, view, _html} = live(ctx.conn, service_path(ctx.version, service))

      loaded(view)

      document = doc(view)

      assert has_element?(view, "#sec-where")
      assert text_of(document, "#where-title") == "Where riders can travel"
      assert count(document, "#f-area li") == 2

      newport = text_of(document, "#f-area-a1")
      assert newport =~ "Newport"
      assert newport =~ "Drawn boundary"
      assert newport =~ ~r/\d+(\.\d)? km²/
      assert newport =~ "Inside:"
      assert newport =~ "stops"

      # Edit area and Add another area both enter the area editor through
      # `push_patch`, which keeps the draft (CR-8) and names the area it opens.
      assert attribute_of(document, "#edit-area-a1", "type") == "button"

      view |> element("#edit-area-a1") |> render_click()

      assert_patched(view, "/gtfs/#{ctx.version.id}/flex/#{service.id}/area?area=a1")
      assert has_element?(view, "#flex-service-area")

      view |> element("#area-back") |> render_click()
      assert_patched(view, service_path(ctx.version, service))

      view |> element("#add-area") |> render_click()
      assert_patched(view, "/gtfs/#{ctx.version.id}/flex/#{service.id}/area?area=new")
    end

    test "connecting stops add and remove on the draft, then save", ctx do
      service = area_service(ctx)
      {:ok, view, _html} = live(ctx.conn, service_path(ctx.version, service))

      loaded(view)

      assert has_element?(view, "#hub-OTR")
      assert has_element?(view, "#hub-DPB")

      view |> element("#remove-hub-OTR") |> render_click()

      refute has_element?(view, "#hub-OTR")
      assert has_element?(view, "#save-bar")

      # The stop is offered again once it is no longer a connecting stop.
      assert has_element?(view, "#hub-stop option[value='OTR']")

      render_change(view, "pick_hub", %{"hub_stop" => "OTR"})
      view |> element("#add-hub") |> render_click()

      assert has_element?(view, "#hub-OTR")

      # Nothing is stored until Save.
      assert stored(ctx, service).hub_stop_ids == ["OTR", "DPB"]

      view
      |> element("#flex-service-form")
      |> render_submit(%{"service" => section_params(service)})

      assert stored(ctx, service).hub_stop_ids == ["DPB", "OTR"]
    end

    test "the stop select offers this version's stops, not another version's", ctx do
      other_version = gtfs_version_fixture(ctx.organization.id)

      GtfsPlanner.GtfsFixtures.stop_fixture(ctx.organization.id, other_version.id, %{
        stop_id: "OTHER-1",
        stop_name: "Other Version Stop"
      })

      service = area_service(ctx)
      {:ok, view, _html} = live(ctx.conn, service_path(ctx.version, service))

      loaded(view)

      assert has_element?(view, "#hub-stop option[value='NP1']")
      refute has_element?(view, "#hub-stop option[value='OTHER-1']")
    end
  end

  describe "where the bus can detour" do
    setup :editor_with_flex_version

    test "the distance select offers the five distances and no default", ctx do
      service = detour_service(ctx)
      {:ok, view, _html} = live(ctx.conn, service_path(ctx.version, service))

      loaded(view)

      document = doc(view)

      assert has_element?(view, "#sec-where")
      assert text_of(document, "#where-title") == "Where the bus can detour"

      assert select_values(document, "#f-distance") == @distance_options

      assert select_labels(document, "#f-distance") == [
               "Choose the distance you publish" | @distance_labels
             ]

      # The stored distance is preselected rather than the placeholder.
      assert selected_value(document, "#f-distance") == "400"
    end

    test "a detour with no distance shows the placeholder, and ADA-only preselects ¾ mile",
         ctx do
      service = detour_service(ctx, %{distance_m: nil})
      {:ok, view, _html} = live(ctx.conn, service_path(ctx.version, service))

      loaded(view)

      document = doc(view)

      assert selected_value(document, "#f-distance") == ""
      assert text_of(document, "#f-distance") =~ "Choose the distance you publish"

      # Choosing ADA-eligible riders only, with no distance published yet,
      # preselects the ¾ mile paratransit minimum (AC-29).
      view
      |> element("#flex-service-form")
      |> render_change(%{"service" => %{"ada_only" => "true", "distance_m" => ""}})

      document = doc(view)

      assert selected_value(document, "#f-distance") == "1200"
      assert has_element?(view, "#save-bar")

      view
      |> element("#flex-service-form")
      |> render_submit(%{
        "service" => section_params(service, %{"ada_only" => "true", "distance_m" => "1200"})
      })

      saved = stored(ctx, service)
      assert saved.distance_m == 1200
      assert saved.ada_only
    end

    test "every detour field saves and re-loads from the database", ctx do
      service = detour_service(ctx)
      {:ok, view, _html} = live(ctx.conn, service_path(ctx.version, service))

      loaded(view)

      params =
        section_params(service, %{
          "wording" => "up to ¾ mile from the route",
          "measure" => "stops",
          "first_stop_id" => "NP2",
          "last_stop_id" => "TLD1",
          "dropoffs" => "book",
          "calendar_service_ids" => ["saturday"],
          "band_mode" => "band",
          "band_start" => "08:00",
          "band_end" => "16:00"
        })

      view |> element("#flex-service-form") |> render_submit(%{"service" => params})

      saved = stored(ctx, service)

      assert saved.wording == "up to ¾ mile from the route"
      assert saved.measure == :stops
      assert saved.first_stop_id == "NP2"
      assert saved.last_stop_id == "TLD1"
      assert saved.dropoffs == :book
      assert saved.calendar_service_ids == ["saturday"]
      assert saved.band_start == "08:00"
      assert saved.band_end == "16:00"

      # The saved page shows the stored answers.
      document = doc(view)

      assert value_of(document, "#f-wording") == "up to ¾ mile from the route"
      assert has_element?(view, "#measure-stops[checked]")
      assert selected_value(document, "#f-first") == "NP2"
      assert selected_value(document, "#f-last") == "TLD1"
      assert has_element?(view, "#dropoffs-book[checked]")
      assert has_element?(view, "#detour-calendar-saturday[checked]")
      refute has_element?(view, "#detour-calendar-weekday[checked]")
      assert value_of(document, "#service_band_start") == "08:00"
      assert value_of(document, "#service_band_end") == "16:00"
      assert has_element?(view, "#band-certain[checked]")

      # And a fresh load reads them back from the database.
      {:ok, reloaded, _html} = live(ctx.conn, service_path(ctx.version, service))
      loaded(reloaded)

      reloaded_document = doc(reloaded)

      assert value_of(reloaded_document, "#f-wording") == "up to ¾ mile from the route"
      assert selected_value(reloaded_document, "#f-first") == "NP2"
      assert has_element?(reloaded, "#band-certain[checked]")
      assert value_of(reloaded_document, "#service_band_end") == "16:00"
    end

    test "choosing All day clears the stored band", ctx do
      service = detour_service(ctx)
      {:ok, view, _html} = live(ctx.conn, service_path(ctx.version, service))

      loaded(view)

      assert has_element?(view, "#band-certain[checked]")

      view
      |> element("#flex-service-form")
      |> render_change(%{"service" => %{"band_mode" => "all"}})

      refute has_element?(view, "#service_band_start")

      view
      |> element("#flex-service-form")
      |> render_submit(%{"service" => section_params(service, %{"band_mode" => "all"})})

      saved = stored(ctx, service)
      assert saved.band_start == nil
      assert saved.band_end == nil
    end

    test "the zone summary is the derived count and size", ctx do
      service = detour_service(ctx)
      {:ok, view, _html} = live(ctx.conn, service_path(ctx.version, service))

      loaded(view)

      summary = doc(view) |> text_of("#where-summary")

      assert summary =~ "3 detour areas, one for each stretch between stops"
      assert summary =~ "km² in all."
    end

    test "a detour field edit is worded in the save bar", ctx do
      service = detour_service(ctx)
      {:ok, view, _html} = live(ctx.conn, service_path(ctx.version, service))

      loaded(view)

      view
      |> element("#flex-service-form")
      |> render_change(%{"service" => %{"distance_m" => "800"}})

      document = doc(view)

      assert text_of(document, "#save-bar") =~ "1 unsaved change to Valley Line detours"
      assert text_of(document, "#save-bar") =~ "Where: Detours up to ½ mile from Route 20"
    end
  end

  describe "who can ride" do
    setup :editor_with_flex_version

    test "choosing registered riders defaults them out of planners and shows their fields",
         ctx do
      service = area_service(ctx)
      {:ok, view, _html} = live(ctx.conn, service_path(ctx.version, service))

      loaded(view)

      assert has_element?(view, "#riders-anyone[checked]")
      refute has_element?(view, "#ada-preset")

      view
      |> element("#flex-service-form")
      |> render_change(%{"service" => %{"riders" => "registered"}})

      # Registered riders default to out of the flex feed, and the fields that
      # only a registered-riders service has appear.
      assert has_element?(view, "#riders-registered[checked]")
      assert has_element?(view, "#publish-no[checked]")
      assert has_element?(view, "#ada-preset")
      assert has_element?(view, "#f-eligibility")
      refute has_element?(view, "#rider-name")
    end

    test "the ADA preset writes the eligibility sentence and the next-day rule", ctx do
      service = registered_service(ctx)
      {:ok, view, _html} = live(ctx.conn, service_path(ctx.version, service))

      loaded(view)

      view |> element("#ada-preset") |> render_click()

      document = doc(view)

      assert value_of(document, "#f-eligibility") =~ "Riders with ADA paratransit eligibility"
      assert has_element?(view, "#booking-when-0-earlier_day[checked]")
      assert value_of(document, "#service_booking_rules_0_by") == "17:00"
      assert value_of(document, "#service_booking_rules_0_days") == "1"
      assert value_of(document, "#service_booking_rules_0_max_days") == "14"

      # Save the preset as rendered; the preset's eligibility text is the one
      # the click put in the draft.
      view
      |> element("#flex-service-form")
      |> render_submit(%{
        "service" =>
          section_params(
            service,
            %{
              "eligibility" =>
                "Riders with ADA paratransit eligibility. Visitors eligible elsewhere may ride up to 21 days a year"
            },
            preset_rule: true
          )
      })

      saved = stored(ctx, service)
      assert saved.eligibility =~ "Riders with ADA paratransit eligibility"

      rule = Enum.find(saved.booking_rules, &is_nil(&1.service_id))
      assert rule.when == :earlier_day
      assert rule.days == 1
      assert rule.by == "17:00"
      assert rule.max_days == 14
      refute rule.business_days
    end

    test "including registered riders states the qualified planner name", ctx do
      service = registered_service(ctx)
      {:ok, view, _html} = live(ctx.conn, service_path(ctx.version, service))

      loaded(view)

      view
      |> element("#flex-service-form")
      |> render_change(%{
        "service" => %{"riders" => "registered", "include_registered" => "true"}
      })

      document = doc(view)

      assert has_element?(view, "#publish-yes[checked]")
      assert text_of(document, "#rider-name") =~ "Newport Access (registered riders)"
    end
  end

  describe "in exports" do
    setup :editor_with_flex_version

    test "the headline is the export plan's and the destination is the switch's", ctx do
      service = area_service(ctx)
      {:ok, view, _html} = live(ctx.conn, service_path(ctx.version, service))

      loaded(view)

      document = doc(view)

      assert has_element?(view, "#sec-export")

      assert text_of(document, "#export-summary") ==
               "Adds 2 areas, 10 flex trips and 2 booking rules."

      assert text_of(document, "#sec-export") =~
               "Goes in the flex file, published with your main feed from the same export."

      # With flex off, the destination says so.
      {:ok, _defaults} = ExportDefaults.update(ctx.organization.id, %{include_flex: false})

      {:ok, view, _html} = live(ctx.conn, service_path(ctx.version, service))
      loaded(view)

      assert text_of(doc(view), "#sec-export") =~ "Exports leave flex out right now"
    end

    test "the realtime answer warns, saves to ExportDefaults and stays out of the draft", ctx do
      service = detour_service(ctx)
      {:ok, view, _html} = live(ctx.conn, service_path(ctx.version, service))

      loaded(view)

      assert has_element?(view, "#f-realtime")
      assert selected_value(doc(view), "#f-realtime") == "unsure"
      assert text_of(doc(view), "#realtime-note") =~ "Ask your vendor"

      render_change(view, "set_realtime", %{"realtime_source" => "own"})

      assert text_of(doc(view), "#realtime-note") =~
               "Apps can’t match its updates to Route 20 trips"

      assert ExportDefaults.get(ctx.organization.id).realtime_source == :own

      # The organization's setting, not the service's: the page keeps no draft.
      refute has_element?(view, "#save-bar")
      assert text_of(doc(view), "#export-r3-note") =~ "stop_sequence doubles"

      # Another organization's answer is untouched.
      other = organization_fixture()

      render_change(view, "set_realtime", %{"realtime_source" => "main"})

      assert ExportDefaults.get(ctx.organization.id).realtime_source == :main
      assert ExportDefaults.get(other.id).realtime_source == :unsure
    end

    test "the export details drawer lists the planned rows with their R11 IDs", ctx do
      service = area_service(ctx)
      {:ok, view, _html} = live(ctx.conn, service_path(ctx.version, service))

      loaded(view)

      refute has_element?(view, "#export-details-overlay[data-open='true']")

      view |> element("#export-details-button") |> render_click()

      assert has_element?(view, "#export-details-overlay[data-open='true']")

      drawer = doc(view)

      assert text_of(drawer, "#export-details-title") == "Export details"

      assert text_of(drawer, "#export-details") =~
               "Adds 2 areas, 10 flex trips and 2 booking rules"

      # R11: location IDs are `flex-<key>-a<position>`, the group is
      # `flex-<key>-stops`, the route is `flex-<key>` and the rules are
      # `flex-<key>-book[-<calendar>]`.
      assert text_of(drawer, "#export-details") =~ "flex-newport-dial-a-ride-a1"
      assert text_of(drawer, "#export-details") =~ "flex-newport-dial-a-ride-a2"
      assert text_of(drawer, "#export-details") =~ "flex-newport-dial-a-ride-stops"
      assert text_of(drawer, "#export-details") =~ "flex-newport-dial-a-ride-book"
      assert text_of(drawer, "#export-details") =~ "flex-newport-dial-a-ride-book-saturday"

      assert text_of(drawer, "#export-details-rows") =~ "locations.geojson"
      assert text_of(drawer, "#export-details-rows") =~ "trips.txt"

      view |> element("#export-details-done") |> render_click()
      refute has_element?(view, "#export-details-overlay[data-open='true']")
    end

    test "a detour's plan names the zone IDs and the route note", ctx do
      service = detour_service(ctx)
      {:ok, view, _html} = live(ctx.conn, service_path(ctx.version, service))

      loaded(view)

      view |> element("#export-details-button") |> render_click()

      drawer = doc(view)

      assert text_of(drawer, "#export-details") =~
               "Changes 2 Route 20 trips: adds 3 detour areas"

      assert text_of(drawer, "#export-details") =~ "flex-valley-line-detours-NP1-NP2"

      assert text_of(drawer, "#export-details") =~
               "the timed stop_sequence doubles so the zone rows sit between them"
    end
  end

  describe "status and removal" do
    setup :editor_with_flex_version

    test "deactivating asks first and then keeps the setup", ctx do
      service = area_service(ctx)
      {:ok, view, _html} = live(ctx.conn, service_path(ctx.version, service))

      loaded(view)

      assert has_element?(view, "#deactivate-service")

      view |> element("#deactivate-service") |> render_click()

      assert has_element?(view, "#flex-service-deactivate-dialog[data-open='true']")

      assert text_of(doc(view), "#flex-service-deactivate-dialog-title") =~
               "Deactivate Newport Dial-a-Ride?"

      assert stored(ctx, service).active

      view |> element("#flex-service-deactivate-dialog-confirm") |> render_click()

      saved = stored(ctx, service)
      refute saved.active
      assert saved.hours != []
      assert has_element?(view, "#reactivate-service")
      assert text_of(doc(view), "#svc-status") =~ "Inactive"

      view |> element("#reactivate-service") |> render_click()

      assert stored(ctx, service).active
      assert has_element?(view, "#deactivate-service")
    end

    test "deleting names the service, removes it and returns to the list", ctx do
      service = area_service(ctx)
      {:ok, view, _html} = live(ctx.conn, service_path(ctx.version, service))

      loaded(view)

      view |> element("#delete-service") |> render_click()

      assert has_element?(view, "#flex-service-delete-dialog[data-open='true']")

      assert text_of(doc(view), "#flex-service-delete-dialog-title") =~
               "Delete Newport Dial-a-Ride?"

      view |> element("#flex-service-delete-dialog-confirm") |> render_click()

      assert_redirect(view, "/gtfs/#{ctx.version.id}/flex")

      assert Flex.get_service(ctx.organization.id, ctx.version.id, service.id) ==
               {:error, :not_found}
    end

    test "the delete confirmation is cancelled without a write", ctx do
      service = area_service(ctx)
      {:ok, view, _html} = live(ctx.conn, service_path(ctx.version, service))

      loaded(view)

      view |> element("#delete-service") |> render_click()
      view |> element("#flex-service-delete-dialog-cancel") |> render_click()

      refute has_element?(view, "#flex-service-delete-dialog[data-open='true']")
      assert {:ok, _service} = Flex.get_service(ctx.organization.id, ctx.version.id, service.id)
    end
  end

  # --- setup ------------------------------------------------------------------

  defp editor_with_flex_version(%{conn: conn}) do
    organization = organization_fixture()
    user = editor_for(organization)
    version = gtfs_version_fixture(organization.id)

    flex_representative_fixture(organization, version)

    %{
      conn: log_in_user(conn, user, organization: organization),
      organization: organization,
      user: user,
      version: version
    }
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

  defp area_service(ctx) do
    service_named(ctx.organization.id, ctx.version.id, "Newport Dial-a-Ride")
  end

  defp registered_service(ctx) do
    service_named(ctx.organization.id, ctx.version.id, "Newport Access")
  end

  # The representative fixture's detour service, with the given fields changed
  # before the page opens (a nil clears one, as the form can).
  defp detour_service(ctx, attrs \\ %{}) do
    service = service_named(ctx.organization.id, ctx.version.id, "Valley Line detours")

    case attrs do
      attrs when map_size(attrs) == 0 ->
        service

      attrs ->
        {:ok, saved} =
          Flex.save_service(ctx.organization.id, ctx.version.id, service, attrs, [])

        saved
    end
  end

  # --- helpers ----------------------------------------------------------------

  defp service_path(version, service), do: "/gtfs/#{version.id}/flex/#{service.id}"

  # The page's answers as its form sends them, with the overrides applied; a
  # save carries every field the page renders, exactly as a browser submit does,
  # so a test never clears an answer it did not mean to.
  defp section_params(service, overrides \\ %{}, opts \\ []) do
    base = %{
      "hours" => hours_params(service),
      "booking_rules" => rule_params(service, opts),
      "phone" => service.phone || "",
      "phone_hours_on" => to_string(service.phone_hours != nil),
      "booking_url" => service.booking_url || "",
      "info_url" => service.info_url || "",
      "note" => service.note || "",
      "riders" => to_string(service.riders),
      "eligibility" => service.eligibility || "",
      "include_registered" => to_string(service.include_registered)
    }

    base
    |> Map.merge(kind_params(service))
    |> Map.merge(overrides)
  end

  defp kind_params(%{kind: :area}), do: %{"hub_stop" => ""}

  defp kind_params(%{kind: :detour} = service) do
    %{
      "distance_m" => integer_param(service.distance_m),
      "wording" => service.wording || "",
      "measure" => to_string(service.measure),
      "first_stop_id" => service.first_stop_id || "",
      "last_stop_id" => service.last_stop_id || "",
      "dropoffs" => to_string(service.dropoffs),
      "ada_only" => to_string(service.ada_only),
      "calendar_service_ids" => service.calendar_service_ids,
      "band_mode" => if(service.band_start || service.band_end, do: "band", else: "all"),
      "band_start" => service.band_start || "",
      "band_end" => service.band_end || ""
    }
  end

  defp kind_params(_service), do: %{}

  defp hours_params(service) do
    service.hours
    |> Enum.with_index()
    |> Map.new(fn {hour, index} ->
      {Integer.to_string(index),
       %{
         "area_key" => hour.area_key || "",
         "service_id" => hour.service_id,
         "start" => hour.start,
         "end" => hour.end
       }}
    end)
  end

  # The rules as the form sends them. `preset_rule: true` sends the ADA
  # preset's own answers instead of the stored ones, because the click's draft
  # answer is not the stored service's.
  defp rule_params(service, opts) do
    service.booking_rules
    |> Enum.with_index()
    |> Map.new(fn {rule, index} ->
      {Integer.to_string(index), rule_row_params(rule, index, opts)}
    end)
  end

  defp rule_row_params(rule, index, opts) do
    if index == 0 and Keyword.get(opts, :preset_rule, false) do
      preset_rule_params()
    else
      stored_rule_params(rule)
    end
  end

  defp preset_rule_params do
    %{
      "service_id" => "",
      "when" => "earlier_day",
      "minutes" => "",
      "days" => "1",
      "by" => "17:00",
      "business_days" => "false",
      "office_service_id" => "",
      "max_days" => "14"
    }
  end

  defp stored_rule_params(%FlexBookingRule{} = rule) do
    %{
      "service_id" => rule.service_id || "",
      "when" => to_string(rule.when || ""),
      "minutes" => integer_param(rule.minutes),
      "days" => integer_param(rule.days),
      "by" => rule.by || "",
      "business_days" => to_string(rule.business_days),
      "office_service_id" => rule.office_service_id || "",
      "max_days" => integer_param(rule.max_days)
    }
  end

  defp integer_param(nil), do: ""
  defp integer_param(value), do: Integer.to_string(value)

  defp stored(ctx, service) do
    {:ok, stored} = Flex.get_service(ctx.organization.id, ctx.version.id, service.id)
    stored
  end

  defp service_named(organization_id, version_id, name) do
    organization_id
    |> Flex.list_services(version_id)
    |> Enum.find(&(&1.name == name))
  end

  defp loaded(view) do
    _ = :sys.get_state(view.pid)
    render(view)
  end

  defp doc(view), do: LazyHTML.from_fragment(render(view))

  defp count(document, selector) do
    document |> LazyHTML.query(selector) |> Enum.count()
  end

  defp text_of(document, selector) do
    document |> LazyHTML.query(selector) |> LazyHTML.text() |> String.trim()
  end

  defp attribute_of(document, selector, name) do
    document |> LazyHTML.query(selector) |> LazyHTML.attribute(name) |> Enum.join(" ")
  end

  defp value_of(document, selector) do
    document |> LazyHTML.query(selector) |> LazyHTML.attribute("value") |> List.first()
  end

  defp select_values(document, selector) do
    document
    |> LazyHTML.query("#{selector} option")
    |> Enum.map(&(&1 |> LazyHTML.attribute("value") |> List.first()))
  end

  defp select_labels(document, selector) do
    document
    |> LazyHTML.query("#{selector} option")
    |> Enum.map(&LazyHTML.text/1)
  end

  # The option a browser would submit: the one the markup marks selected, or the
  # first option when it marks none, which is the select's own default (the
  # distance placeholder is rendered as an unselected first option).
  defp selected_value(document, selector) do
    options =
      document
      |> LazyHTML.query("#{selector} option")
      |> Enum.to_list()

    marked =
      Enum.find(options, fn option ->
        option |> LazyHTML.attribute("selected") |> List.first() != nil
      end)

    case marked || List.first(options) do
      nil -> nil
      option -> option |> LazyHTML.attribute("value") |> List.first()
    end
  end
end
