defmodule GtfsPlannerWeb.Gtfs.FlexServiceLiveTest do
  @moduledoc """
  Merge evidence (EV-22) for the flex service page and its one Save (AC-5).

  The page is judged as the editor works it: the header's readiness badge, the
  hours editor and the booking choices, the rider and booking previews that
  follow the draft, and the map card. An edit marks the page dirty and the save
  bar words it in rider terms before anything is stored; Save persists the whole
  page through `Flex.save_service/5` and clears the draft, a changeset refusal
  keeps the draft and lists every problem with a link to its control.

  The conflict is judged with two sessions on one service (R10, FH-23): the
  second save answers `:stale`, keeps its draft and offers the prototype's two
  ways out — reload their saved values, or save this draft on top of their row.
  Leaving with unsaved changes asks first, and Discard reloads the saved service.

  The focused command is deferred to branch review:
  `mix test test/gtfs_planner_web/live/gtfs/flex_service_live_test.exs`.
  """
  use GtfsPlannerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.FlexFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Gtfs.Flex
  alias GtfsPlanner.Gtfs.Flex.RiderText

  describe "the service page" do
    setup :editor_with_flex_version

    test "renders the header, the hours and booking sections, the previews and the map", ctx do
      service = service_named(ctx.organization.id, ctx.version.id, "Newport Dial-a-Ride")
      {:ok, view, _html} = live(ctx.conn, service_path(ctx.version, service))

      loaded(view)

      document = doc(view)

      assert text_of(document, "#svc-title") == "Newport Dial-a-Ride"
      assert text_of(document, "#svc-status") =~ "Ready"
      assert text_of(document, "#flex-service-page") =~ "Anywhere in Newport or Toledo"

      # The reference's section order: hours first, then booking.
      assert positions(document, ["sec-when", "sec-booking"]) == ["sec-when", "sec-booking"]

      # One row per stored window, with the areas the service has and the
      # calendars the version has, and the calendar's own days and dates under
      # each row.
      assert count(document, "#f-hours .fieldset") == 4 * 4

      assert select_values(document, "#service_hours_0_service_id") ==
               ["office", "saturday", "weekday"]

      assert text_of(document, "#f-hours-row-0") =~ "Mon–Fri"
      assert text_of(document, "#f-hours-row-0") =~ "Jan 1, 2026 – Dec 31, 2026"

      # The week strip draws the seven days and the windows each calendar runs.
      assert count(document, "#week-strip div[class*='items-center']") == 7
      assert text_of(document, "#week-strip") =~ "7 am–6 pm, 9 am–3 pm"

      # The previews are the same text the export writes (R5, R7).
      assert text_of(document, "#rider-preview") =~ RiderText.message(service, ctx.calendars)
      assert text_of(document, "#rider-preview") =~ "Weekdays 7:00 am–6:00 pm"

      assert text_of(document, "#booking-preview") =~ "Transit app"

      assert text_of(document, "#booking-preview") =~
               "Book Monday trips by 4:00 pm the Friday before"

      # A clean page has no save bar and no draft flag.
      refute has_element?(view, "#save-bar")
      assert attribute_of(document, "#flex-service-page", "data-dirty") == "false"
    end

    test "the next days without service come from the service's own calendars", ctx do
      date = Date.add(Date.utc_today(), 4)

      GtfsPlanner.GtfsFixtures.calendar_date_fixture(ctx.organization.id, ctx.version.id, %{
        service_id: "weekday",
        date: date,
        exception_type: 2
      })

      service = service_named(ctx.organization.id, ctx.version.id, "Newport Dial-a-Ride")
      {:ok, view, _html} = live(ctx.conn, service_path(ctx.version, service))

      loaded(view)

      document = doc(view)

      assert text_of(document, "#service-exceptions") =~ "Next days without service:"
      assert text_of(document, "#service-exceptions") =~ Calendar.strftime(date, "%a, %b %-d")

      assert attribute_of(document, "#service-exceptions a", "href") ==
               "/gtfs/#{ctx.version.id}/calendars"
    end

    test "an hours edit dirties the page, words the change and updates the preview", ctx do
      service = single_window_service(ctx)
      {:ok, view, _html} = live(ctx.conn, service_path(ctx.version, service))

      loaded(view)

      view
      |> element("#flex-service-form")
      |> render_change(%{"service" => hours_params(service, end: "17:00")})

      document = doc(view)

      assert attribute_of(document, "#flex-service-page", "data-dirty") == "true"
      assert text_of(document, "#save-bar") =~ "1 unsaved change to Weekday Dial-a-Ride"

      assert text_of(document, "#save-bar") =~
               "Weekdays: 7:00 am–6:00 pm → 7:00 am–5:00 pm"

      assert text_of(document, "#rider-preview") =~ "Weekdays 7:00 am–5:00 pm"

      # Nothing is stored before Save.
      assert stored(ctx, service).hours == service.hours
    end

    test "an answer the form does not render survives a change and a save", ctx do
      # One area renders no area select on the hours rows, so the row's area is
      # never in a change payload; the draft and the save must keep it.
      {:ok, service} =
        Flex.create_service(ctx.organization.id, ctx.version.id, %{
          name: "One Area Flex",
          kind: :area
        })

      {:ok, service} =
        Flex.save_service(
          ctx.organization.id,
          ctx.version.id,
          service,
          %{
            phone: "(541) 555-0142",
            hours: [%{area_key: "a1", service_id: "weekday", start: "07:00", end: "18:00"}],
            booking_rules: [%{when: :same_day, minutes: 30}]
          },
          [%{key: "a1", name: "Newport", source: :drawn, geojson: newport_area()}]
        )

      {:ok, view, _html} = live(ctx.conn, service_path(ctx.version, service))

      loaded(view)

      refute has_element?(view, "#service_hours_0_area_key")
      assert text_of(doc(view), "#rider-preview") =~ "Newport only: Weekdays 7:00 am–6:00 pm"

      view
      |> element("#flex-service-form")
      |> render_change(%{"service" => hours_params(service, end: "17:00")})

      assert text_of(doc(view), "#rider-preview") =~ "Newport only: Weekdays 7:00 am–5:00 pm"

      view
      |> element("#flex-service-form")
      |> render_submit(%{"service" => hours_params(service, end: "17:00")})

      assert Enum.map(stored(ctx, service).hours, &{&1.area_key, &1.start, &1.end}) ==
               [{"a1", "07:00", "17:00"}]
    end

    test "adding and removing an hours row changes the draft only", ctx do
      service = service_named(ctx.organization.id, ctx.version.id, "Newport Dial-a-Ride")
      {:ok, view, _html} = live(ctx.conn, service_path(ctx.version, service))

      loaded(view)
      view |> element("#add-hours") |> render_click()

      document = doc(view)

      assert has_element?(view, "#f-hours-row-4")
      assert value_of(document, "#service_hours_4_start") == "09:00"
      assert value_of(document, "#service_hours_4_end") == "17:00"
      assert selected_value(document, "#service_hours_4_service_id") == "office"

      view |> element("#remove-hours-0") |> render_click()

      # The removed row is gone and the rest keep their answers in order.
      refute has_element?(view, "#f-hours-row-4")
      assert value_of(doc(view), "#service_hours_0_start") == "09:00"
      assert length(stored(ctx, service).hours) == 4
    end

    test "each booking type reveals only its fields and the preview follows them", ctx do
      service = single_window_service(ctx)
      {:ok, view, _html} = live(ctx.conn, service_path(ctx.version, service))

      loaded(view)

      view
      |> element("#flex-service-form")
      |> render_change(%{"service" => rule_params(service, when: "same_day")})

      document = doc(view)

      assert has_element?(view, "#service_booking_rules_0_minutes")
      refute has_element?(view, "#service_booking_rules_0_by")
      refute has_element?(view, "#service_booking_rules_0_business_days")
      assert text_of(document, "#booking-preview") =~ "Book at least 30 minutes before pickup"

      view
      |> element("#flex-service-form")
      |> render_change(%{"service" => rule_params(service, when: "earlier_day")})

      document = doc(view)

      assert has_element?(view, "#service_booking_rules_0_by")
      assert has_element?(view, "#service_booking_rules_0_days")
      assert has_element?(view, "#service_booking_rules_0_business_days")
      refute has_element?(view, "#service_booking_rules_0_minutes")

      # The office-days calendar follows the business-days answer, and the
      # generated text gains the Monday sentence (R7).
      assert select_values(document, "#service_booking_rules_0_office_service_id") ==
               ["", "office", "saturday", "weekday"]

      assert text_of(document, "#booking-preview") =~
               "Book Monday trips by 4:00 pm the Friday before"

      # Turning the phone line's set hours on starts the prototype's hours and
      # words them in the rider text.
      view
      |> element("#flex-service-form")
      |> render_change(%{
        "service" => Map.put(rule_params(service, when: "earlier_day"), "phone_hours_on", "true")
      })

      document = doc(view)

      assert value_of(document, "#phone-hours-from") == "08:00"
      assert text_of(document, "#rider-preview") =~ "(Mon–Fri 8 am–5 pm)"
    end

    test "an area service adds and removes a rule for one calendar", ctx do
      service = service_named(ctx.organization.id, ctx.version.id, "Newport Dial-a-Ride")
      {:ok, view, _html} = live(ctx.conn, service_path(ctx.version, service))

      loaded(view)

      # The fixture's Saturday rule renders as the second rule.
      assert has_element?(view, "#remove-scoped-rule-1")

      view |> element("#remove-scoped-rule-1") |> render_click()

      document = doc(view)

      refute has_element?(view, "#remove-scoped-rule-1")
      assert text_of(document, "#save-bar") =~ "Saturday booking rule removed"

      view |> element("#add-scoped-rule") |> render_click()

      document = doc(view)

      assert has_element?(view, "#remove-scoped-rule-1")
      assert selected_value(document, "#service_booking_rules_1_service_id") == "office"
      assert value_of(document, "#service_booking_rules_1_days") == "2"
      assert value_of(document, "#service_booking_rules_1_by") == "17:00"
    end

    test "a detour service offers no extra rule and its own hours heading", ctx do
      service = service_named(ctx.organization.id, ctx.version.id, "Valley Line detours")
      {:ok, view, _html} = live(ctx.conn, service_path(ctx.version, service))

      loaded(view)

      document = doc(view)

      assert text_of(document, "#when-title") == "Which trips offer detours"
      refute has_element?(view, "#add-hours")
      refute has_element?(view, "#add-scoped-rule")
      assert has_element?(view, "#service_booking_rules_0_by")
      assert text_of(document, "#rider-preview") =~ "On Route 20 trips: weekdays and Saturdays"
    end

    test "the note's character count turns into a warning above the limit", ctx do
      service = single_window_service(ctx)
      {:ok, view, _html} = live(ctx.conn, service_path(ctx.version, service))

      loaded(view)

      view
      |> element("#flex-service-form")
      |> render_change(%{
        "service" => note_params(service, "Tell the dispatcher about a wheelchair.")
      })

      document = doc(view)

      assert text_of(document, "#note-count") =~ "Text riders read: "
      assert text_of(document, "#note-count") =~ " of about 250 characters"
      refute class_of(document, "#note-count") =~ "text-warning-fg"

      view
      |> element("#flex-service-form")
      |> render_change(%{"service" => note_params(service, String.duplicate("a", 400))})

      document = doc(view)

      assert class_of(document, "#note-count") =~ "text-warning-fg"
    end

    test "Save persists the page and clears dirty", ctx do
      service = single_window_service(ctx)
      {:ok, view, _html} = live(ctx.conn, service_path(ctx.version, service))

      loaded(view)

      view
      |> element("#flex-service-form")
      |> render_submit(%{
        "service" =>
          service
          |> hours_params(end: "17:00")
          |> Map.merge(%{
            "note" => "Tell the dispatcher about a wheelchair.",
            "booking_url" => "https://example.org/new"
          })
      })

      stored = stored(ctx, service)

      assert Enum.map(stored.hours, &{&1.service_id, &1.start, &1.end}) ==
               [{"weekday", "07:00", "17:00"}]

      assert stored.note == "Tell the dispatcher about a wheelchair."
      assert stored.booking_url == "https://example.org/new"
      assert stored.lock_version == service.lock_version + 1

      # The page is clean again, and the fields this page does not render are
      # still the stored ones.
      assert attribute_of(doc(view), "#flex-service-page", "data-dirty") == "false"
      refute has_element?(view, "#save-bar")
      assert stored.key == service.key and stored.hub_stop_ids == service.hub_stop_ids
    end

    test "a save with an invalid phone lists the problem and stores nothing", ctx do
      service = single_window_service(ctx)
      {:ok, view, _html} = live(ctx.conn, service_path(ctx.version, service))

      loaded(view)

      view
      |> element("#flex-service-form")
      |> render_submit(%{
        "service" => Map.put(hours_params(service, end: "17:00"), "phone", "555-0142")
      })

      document = doc(view)

      assert has_element?(view, "#flex-service-error-summary")
      assert attribute_of(document, "#flex-service-error-summary a", "href") == "#service_phone"

      assert text_of(document, "#flex-service-error-summary") =~
               "Enter the phone number as 10 digits"

      # Inline on the field, and nothing stored.
      assert attribute_of(document, "#service_phone", "aria-invalid") == "true"
      assert value_of(document, "#service_phone") == "555-0142"
      assert stored(ctx, service).hours == service.hours
      assert stored(ctx, service).lock_version == service.lock_version
      assert has_element?(view, "#save-bar")

      # Answering the field clears the summary; the follow-up change submits the
      # stored hours end too, because the refused save above had also drafted
      # 17:00 against the stored 18:00. Nothing is unsaved once both are back.
      view
      |> element("#flex-service-form")
      |> render_change(%{"service" => hours_params(service, end: "18:00")})

      refute has_element?(view, "#flex-service-error-summary")
      refute has_element?(view, "#save-bar")
    end

    test "an hours row with no start links its problem to that row", ctx do
      service = single_window_service(ctx)
      {:ok, view, _html} = live(ctx.conn, service_path(ctx.version, service))

      loaded(view)

      params = put_in(hours_params(service, end: "17:00"), ["hours", "0", "start"], "")

      view
      |> element("#flex-service-form")
      |> render_submit(%{"service" => params})

      document = doc(view)

      assert has_element?(view, "#flex-service-error-summary")

      assert attribute_of(document, "#flex-service-error-summary a", "href") ==
               "#service_hours_0_start"

      assert attribute_of(document, "#service_hours_0_start", "aria-invalid") == "true"

      # The refused form is still the draft's own row: no doubled editor. A
      # single-area service renders no Area select, so the row's three inputs
      # (calendar, From, To) are the count.
      assert count(document, "#f-hours .fieldset") == 3
      assert stored(ctx, service).hours == service.hours
    end
  end

  describe "two sessions on one service" do
    setup :editor_with_flex_version

    test "a save after another session's save answers stale and keeps the draft", ctx do
      service = single_window_service(ctx)
      {:ok, first, _html} = live(ctx.conn, service_path(ctx.version, service))
      {:ok, second, _html} = live(ctx.conn, service_path(ctx.version, service))

      loaded(first)
      loaded(second)

      first
      |> element("#flex-service-form")
      |> render_submit(%{
        "service" => service |> hours_params(end: "16:00") |> Map.put("note", "First editor.")
      })

      html =
        second
        |> element("#flex-service-form")
        |> render_submit(%{
          "service" => service |> hours_params(end: "15:00") |> Map.put("note", "Second editor.")
        })

      assert html =~ "Someone else saved this service while you were editing."
      assert html =~ "They changed: Weekdays: 7:00 am–6:00 pm → 7:00 am–4:00 pm"

      # The second session keeps its own draft.
      assert has_element?(second, "#save-bar")
      assert value_of(doc(second), "#service_hours_0_end") == "15:00"
      assert stored(ctx, service).note == "First editor."
    end

    test "\"Use their changes\" reloads the saved values", ctx do
      service = single_window_service(ctx)
      {:ok, first, _html} = live(ctx.conn, service_path(ctx.version, service))
      {:ok, second, _html} = live(ctx.conn, service_path(ctx.version, service))

      loaded(first)
      loaded(second)

      first
      |> element("#flex-service-form")
      |> render_submit(%{"service" => hours_params(service, end: "16:00")})

      second
      |> element("#flex-service-form")
      |> render_submit(%{"service" => hours_params(service, end: "15:00")})

      second |> element("#stale-theirs") |> render_click()

      document = doc(second)

      refute has_element?(second, "#flex-service-stale")
      refute has_element?(second, "#save-bar")
      assert value_of(document, "#service_hours_0_end") == "16:00"
      assert attribute_of(document, "#flex-service-page", "data-dirty") == "false"
    end

    test "\"Save both changes\" merges this draft onto their saved row", ctx do
      service = single_window_service(ctx)
      {:ok, first, _html} = live(ctx.conn, service_path(ctx.version, service))
      {:ok, second, _html} = live(ctx.conn, service_path(ctx.version, service))

      loaded(first)
      loaded(second)

      first
      |> element("#flex-service-form")
      |> render_submit(%{
        "service" => service |> hours_params(end: "16:00") |> Map.put("note", "First editor.")
      })

      second
      |> element("#flex-service-form")
      |> render_submit(%{
        "service" => service |> hours_params(end: "15:00") |> Map.put("note", "Second editor.")
      })

      assert has_element?(second, "#flex-service-stale")

      # A third session opens after the first save, so its own save lands and
      # their row moves on once more; the second session is stale again on its
      # next save.
      {:ok, third, _html} = live(ctx.conn, service_path(ctx.version, service))
      loaded(third)

      third
      |> element("#flex-service-form")
      |> render_submit(%{"service" => hours_params(service, end: "17:00")})

      second
      |> element("#flex-service-form")
      |> render_submit(%{
        "service" => service |> hours_params(end: "15:00") |> Map.put("note", "Second editor.")
      })

      second |> element("#stale-both") |> render_click()

      stored = stored(ctx, service)

      assert Enum.map(stored.hours, &{&1.service_id, &1.end}) == [{"weekday", "15:00"}]
      assert stored.note == "Second editor."
      assert stored.lock_version == service.lock_version + 3
      refute has_element?(second, "#flex-service-stale")
      refute has_element?(second, "#save-bar")
    end
  end

  describe "unsaved changes" do
    setup :editor_with_flex_version

    test "the guard flags the page and an in-app departure asks first", ctx do
      service = single_window_service(ctx)
      {:ok, view, _html} = live(ctx.conn, service_path(ctx.version, service))

      loaded(view)

      assert attribute_of(doc(view), "#flex-service-page", "data-dirty") == "false"

      view
      |> element("#flex-service-form")
      |> render_change(%{"service" => hours_params(service, end: "17:00")})

      assert attribute_of(doc(view), "#flex-service-page", "data-dirty") == "true"

      render_hook(view, "flex_depart", %{"path" => version_flex_path(ctx.version, service)})

      assert attribute_of(doc(view), "#flex-service-leave-dialog", "data-open") == "true"

      # A path the page did not author never opens the dialog.
      render_hook(view, "flex_depart", %{"path" => "https://example.org/elsewhere"})

      assert has_element?(view, "#save-bar")

      view |> element("#flex-service-leave-dialog-cancel") |> render_click()

      assert has_element?(view, "#save-bar")
      refute has_element?(view, "#flex-service-leave-dialog[data-open='true']")
    end

    test "Discard changes asks, and reloads the saved service", ctx do
      service = single_window_service(ctx)
      {:ok, view, _html} = live(ctx.conn, service_path(ctx.version, service))

      loaded(view)

      view
      |> element("#flex-service-form")
      |> render_change(%{"service" => hours_params(service, end: "17:00")})

      view |> element("#discard-changes") |> render_click()

      assert attribute_of(doc(view), "#flex-service-discard-dialog", "data-open") == "true"

      view |> element("#flex-service-discard-dialog-cancel") |> render_click()

      assert has_element?(view, "#save-bar")

      view |> element("#discard-changes") |> render_click()
      view |> element("#flex-service-discard-dialog-confirm") |> render_click()

      document = doc(view)

      refute has_element?(view, "#save-bar")
      assert value_of(document, "#service_hours_0_end") == "18:00"
      assert attribute_of(document, "#flex-service-page", "data-dirty") == "false"
    end
  end

  describe "states" do
    setup :editor_with_flex_version

    test "a service this version does not hold offers the way back", ctx do
      {:ok, view, _html} = live(ctx.conn, "/gtfs/#{ctx.version.id}/flex/#{Ecto.UUID.generate()}")

      loaded(view)

      assert has_element?(view, "#flex-service-not-found")

      assert attribute_of(doc(view), "#flex-service-back", "href") ==
               "/gtfs/#{ctx.version.id}/flex"
    end

    test "the area action keeps the draft and returns to the service", ctx do
      service = service_named(ctx.organization.id, ctx.version.id, "Newport Dial-a-Ride")
      {:ok, view, _html} = live(ctx.conn, service_path(ctx.version, service) <> "/area")

      loaded(view)

      assert has_element?(view, "#flex-service-area")
      refute has_element?(view, "#sec-when")

      view |> element("#area-back") |> render_click()

      assert has_element?(view, "#sec-when")
      refute has_element?(view, "#flex-service-area")
    end

    test "a service of another version is not found on this version's page", ctx do
      other_version = gtfs_version_fixture(ctx.organization.id)
      service = service_named(ctx.organization.id, ctx.version.id, "Newport Dial-a-Ride")

      assert Flex.get_service(ctx.organization.id, other_version.id, service.id) ==
               {:error, :not_found}

      {:ok, view, _html} = live(ctx.conn, "/gtfs/#{other_version.id}/flex/#{service.id}")

      loaded(view)

      assert has_element?(view, "#flex-service-not-found")
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
      version: version,
      calendars: Flex.calendars_map(organization.id, version.id)
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

  # One area service with one weekday window and one rule, so the save bar's
  # rider-terms lines are asserted against a single calendar.
  defp single_window_service(ctx) do
    {:ok, service} =
      Flex.create_service(ctx.organization.id, ctx.version.id, %{
        name: "Weekday Dial-a-Ride",
        kind: :area
      })

    {:ok, service} =
      Flex.save_service(
        ctx.organization.id,
        ctx.version.id,
        service,
        %{
          phone: "(541) 555-0142",
          booking_url: "https://example.org/book",
          hours: [%{area_key: nil, service_id: "weekday", start: "07:00", end: "18:00"}],
          booking_rules: [%{when: :same_day, minutes: 30}]
        },
        [%{key: "a1", name: "Newport", source: :drawn, geojson: newport_area()}]
      )

    service
  end

  defp newport_area do
    %{
      "type" => "Polygon",
      "coordinates" => [
        [
          [-124.075, 44.595],
          [-124.045, 44.595],
          [-124.045, 44.625],
          [-124.075, 44.625],
          [-124.075, 44.595]
        ]
      ]
    }
  end

  # --- helpers ----------------------------------------------------------------

  defp service_path(version, service), do: "/gtfs/#{version.id}/flex/#{service.id}"
  defp version_flex_path(version, _service), do: "/gtfs/#{version.id}/flex"

  # The page's own answers, as its form sends them: the area select exists only
  # when the service has several areas, and only the window named by `:end` moves.
  defp hours_params(service, opts) do
    multi_area? = length(service.areas) > 1

    hours =
      service.hours
      |> Enum.with_index()
      |> Map.new(fn {hour, index} ->
        {Integer.to_string(index), hours_row_params(hour, index, opts, multi_area?)}
      end)

    rules =
      service.booking_rules
      |> Enum.with_index()
      |> Map.new(fn {rule, index} -> {Integer.to_string(index), rule_row_params(rule)} end)

    %{
      "hours" => hours,
      "booking_rules" => rules,
      "phone" => service.phone || "",
      "phone_hours_on" => to_string(service.phone_hours != nil),
      "booking_url" => service.booking_url || "",
      "info_url" => service.info_url || "",
      "note" => service.note || ""
    }
  end

  defp hours_row_params(hour, index, opts, multi_area?) do
    row = %{
      "service_id" => hour.service_id,
      "start" => hour.start,
      "end" => if(index == 0 and opts[:end], do: opts[:end], else: hour.end)
    }

    if multi_area?, do: Map.put(row, "area_key", hour.area_key || ""), else: row
  end

  defp rule_row_params(rule) do
    %{
      "service_id" => rule.service_id || "",
      "when" => to_string(rule.when || ""),
      "minutes" => integer_param(rule.minutes),
      "days" => integer_param(rule.days),
      "by" => rule.by || "",
      "business_days" => to_string(rule.business_days),
      "office_service_id" => rule.office_service_id || ""
    }
  end

  defp integer_param(nil), do: ""
  defp integer_param(value), do: Integer.to_string(value)

  defp rule_params(service, opts) do
    service
    |> hours_params([])
    |> Map.put("booking_rules", %{
      "0" => %{
        "service_id" => "",
        "when" => opts[:when],
        "minutes" => "30",
        "days" => "1",
        "by" => "16:00",
        "business_days" => "true",
        "office_service_id" => "office"
      }
    })
  end

  defp note_params(service, note) do
    service |> hours_params([]) |> Map.put("note", note)
  end

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

  defp class_of(document, selector) do
    document |> LazyHTML.query(selector) |> LazyHTML.attribute("class") |> Enum.join(" ")
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

  defp selected_value(document, selector) do
    document
    |> LazyHTML.query("#{selector} option")
    |> Enum.find(fn option -> option |> LazyHTML.attribute("selected") |> List.first() != nil end)
    |> case do
      nil -> nil
      option -> option |> LazyHTML.attribute("value") |> List.first()
    end
  end

  defp positions(document, ids) do
    html = LazyHTML.to_html(document)

    ids
    |> Enum.map(fn id -> {id, :binary.match(html, "id=\"#{id}\"") |> elem(0)} end)
    |> Enum.sort_by(&elem(&1, 1))
    |> Enum.map(&elem(&1, 0))
  end
end
