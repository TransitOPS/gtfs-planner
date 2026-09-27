defmodule GtfsPlannerWeb.Gtfs.RouteSchedulesEditingTest do
  # EV-6: the Schedules mutation surface — the Add, Edit and Duplicate drawers,
  # the row actions, the bulk toolbar and the delete confirmations, wired to the
  # real `Gtfs` facade and the real `Gtfs.Schedules` writers.
  #
  # Every case mounts through the authenticated router, so the production
  # composition is exercised end to end: LiveView event -> `Gtfs` facade ->
  # `Gtfs.Schedules` transaction -> audit -> reload through the read adapter.
  # Persisted rows are asserted with independent `Repo` queries, never from the
  # rendered HTML alone.
  use GtfsPlannerWeb.ConnCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.AuditContext
  alias GtfsPlanner.Gtfs.StopTime
  alias GtfsPlanner.Gtfs.Trip
  alias GtfsPlanner.Repo
  alias GtfsPlannerWeb.Gtfs.ScheduleComponents

  @weekday "EDT_WKD"
  @saturday "EDT_SAT"

  setup context do
    organization = organization_fixture(%{alias: "editing-#{System.unique_integer([:positive])}"})

    user =
      user_fixture(%{email: "editing-#{System.unique_integer([:positive])}@example.com"})

    {:ok, membership} =
      Accounts.create_user_org_membership(%{
        user_id: user.id,
        organization_id: organization.id,
        roles: ["pathways_studio_editor"]
      })

    version = gtfs_version_fixture(organization.id)

    {:ok,
     conn: log_in_user(context.conn, user, organization: organization),
     organization: organization,
     organization_id: organization.id,
     user: user,
     membership: membership,
     version: version}
  end

  describe "editor role" do
    test "a revoked editor role refuses every mutating event with no write", context do
      scope = editing_scope(context)
      {:ok, view, _html} = live(context.conn, schedules_path(scope))
      open_add_drawer(view)

      {:ok, _membership} =
        Accounts.update_user_org_membership(context.membership, %{
          roles: ["pathways_studio_viewer"]
        })

      before = count_trips(scope)

      html =
        render_submit(view, "drawer_submit", %{
          "drawer" => add_params(scope, %{"start_time" => "06:00"})
        })

      # The event is refused before any context call, so the drawer keeps its
      # input and shows the fixed copy; nothing was written.
      assert html =~ "You don't have permission to change this route's trips."
      assert count_trips(scope) == before
    end

    test "a forged trip id opens nothing and writes nothing", context do
      scope = editing_scope(context)
      {:ok, view, _html} = live(context.conn, schedules_path(scope))

      forged = Ecto.UUID.generate()
      before = count_trips(scope)

      render_click(view, "open_edit_drawer", %{"trip" => forged})
      render_click(view, "open_delete_trip", %{"trip" => forged})

      refute has_element?(view, "#trip-drawer[data-open='true']")
      refute has_element?(view, "#delete-dialog[data-open='true']")
      assert count_trips(scope) == before
    end

    test "a trip on another route is not editable here and is never written", context do
      scope = editing_scope(context)
      {:ok, view, _html} = live(context.conn, schedules_path(scope))

      other_route =
        route_fixture(scope.organization_id, scope.version.id, %{
          route_id: "EDT_OTHER",
          route_short_name: "E9"
        })

      other_calendar =
        weekly_calendar(scope, "EDT_OTHER_WKD", "Other weekday")

      other_pattern =
        schedule_pattern_fixture(scope.organization_id, scope.version.id, %{
          route_id: other_route.route_id,
          route_pattern_id: "EDT-OTHER-P1",
          route_pattern_name: "Other pattern",
          timing_name: "Other timing",
          stops: [{"EDT_S1", 0, 0, 1}, {"EDT_S2", 600, 600, 1}]
        })

      other =
        schedule_trip_fixture(
          scope.organization_id,
          scope.version.id,
          other_route.route_id,
          other_pattern,
          %{service_id: other_calendar, trip_id: "EDT_OTHER_T1", start_time: "06:00:00"}
        )

      render_click(view, "open_edit_drawer", %{"trip" => other.trip.id})

      refute has_element?(view, "#trip-drawer[data-open='true']")
      assert count_trips(scope, "EDT_OTHER_T1") == 1
    end

    test "a forged pattern or timing id renders the fixed copy and writes nothing", context do
      scope = editing_scope(context)
      {:ok, view, _html} = live(context.conn, schedules_path(scope))

      open_add_drawer(view)
      before = count_trips(scope)

      html =
        render_submit(view, "drawer_submit", %{
          "drawer" =>
            add_params(scope, %{"pattern_id" => Ecto.UUID.generate(), "start_time" => "06:00"})
        })

      assert html =~ ScheduleComponents.error_message(:not_found)
      assert count_trips(scope) == before

      html =
        render_submit(view, "drawer_submit", %{
          "drawer" =>
            add_params(scope, %{
              "timed_pattern_id" => Ecto.UUID.generate(),
              "start_time" => "06:00"
            })
        })

      assert html =~ ScheduleComponents.error_message(:not_found)
      assert count_trips(scope) == before
    end
  end

  describe "add trips" do
    test "the previewed series is exactly what is created", context do
      scope = editing_scope(context)
      {:ok, view, _html} = live(context.conn, schedules_path(scope))
      open_add_drawer(view)

      every_params = %{
        "start_time" => "06:00",
        "repeat" => "true",
        "every" => "30",
        "until" => "07:00"
      }

      preview =
        render_change(view, "drawer_change", %{"drawer" => add_params(scope, every_params)})

      assert preview =~ "Adds 3 trips, 06:00 → 07:00 every 30 min."
      assert preview =~ "Add 3 trips"

      # A preview with a bad window refuses and says why, with no write.
      before = count_trips(scope)

      error =
        render_change(view, "drawer_change", %{
          "drawer" =>
            add_params(scope, %{
              "start_time" => "07:00",
              "repeat" => "true",
              "every" => "30",
              "until" => "06:00"
            })
        })

      assert error =~ ScheduleComponents.error_message(:until_before_start)
      assert count_trips(scope) == before

      html = render_submit(view, "drawer_submit", %{"drawer" => add_params(scope, every_params)})

      assert html =~ "Added 3 trips to Weekday."
      assert_patched(view, schedules_path(scope, %{"pattern" => scope.long.pattern.id}))

      # The three persisted rows carry the previewed departures and the scoped
      # allocated IDs, read back with an independent query.
      assert created_trip_ids(scope) == [
               "EDT1-0-EDT_WKD-0600-2",
               "EDT1-0-EDT_WKD-0630",
               "EDT1-0-EDT_WKD-0700-2"
             ]

      assert first_departures(scope, [
               "EDT1-0-EDT_WKD-0600-2",
               "EDT1-0-EDT_WKD-0630",
               "EDT1-0-EDT_WKD-0700-2"
             ]) ==
               ["06:00:00", "06:30:00", "07:00:00"]
    end

    test "the departure copy is fixed and focus lands on the invalid field", context do
      scope = editing_scope(context)
      {:ok, view, _html} = live(context.conn, schedules_path(scope))
      open_add_drawer(view)

      before = count_trips(scope)

      html =
        render_submit(view, "drawer_submit", %{
          "drawer" => add_params(scope, %{"start_time" => "25:9"})
        })

      assert html =~ "Enter a departure as HH:MM, for example 06:00 or 25:10."
      assert html =~ ~s(id="trip-start")
      assert html =~ ~s(aria-invalid="true")

      assert_push_event(view, "focus_form_error", %{
        form_id: "trip-drawer-form",
        fallback_id: "trip-start"
      })

      assert count_trips(scope) == before
    end

    test "a whole-number interval is required and an unaligned end is included only when it lands on a departure",
         context do
      scope = editing_scope(context)
      {:ok, view, _html} = live(context.conn, schedules_path(scope))
      open_add_drawer(view)

      html =
        render_change(view, "drawer_change", %{
          "drawer" =>
            add_params(scope, %{
              "start_time" => "06:00",
              "repeat" => "true",
              "every" => "0",
              "until" => "07:00"
            })
        })

      assert html =~ "Enter a whole number of minutes greater than zero."

      preview =
        render_change(view, "drawer_change", %{
          "drawer" =>
            add_params(scope, %{
              "start_time" => "06:00",
              "repeat" => "true",
              "every" => "25",
              "until" => "07:00"
            })
        })

      # 06:00, 06:25, 06:50 — the unaligned 07:00 is not included.
      assert preview =~ "Adds 3 trips, 06:00 → 06:50 every 25 min."
    end
  end

  describe "edit trip" do
    test "a linked retime keeps row ids and moves the stored times", context do
      scope = editing_scope(context)
      {:ok, view, _html} = live(context.conn, schedules_path(scope))

      trip = trip_row(scope, "EDT_T0600")
      before_rows = stop_times(scope, "EDT_T0600")

      render_click(view, "open_edit_drawer", %{"trip" => trip.id})
      assert has_element?(view, "#trip-drawer[data-open='true']")

      html =
        render_submit(view, "drawer_submit", %{
          "drawer" =>
            edit_params(scope, %{
              "start_time" => "05:00",
              "timed_pattern_id" => scope.long.timing.id,
              "service_id" => @weekday,
              "trip_headsign" => "Retimed",
              "block_id" => "E-7",
              "trip_short_name" => "9001",
              "wheelchair_accessible" => "1",
              "bikes_allowed" => "2"
            })
        })

      assert html =~ "Saved the 05:00 trip."
      refute has_element?(view, "#trip-drawer[data-open='true']")

      after_rows = stop_times(scope, "EDT_T0600")

      assert Enum.map(after_rows, & &1.id) == Enum.map(before_rows, & &1.id)
      assert Enum.map(after_rows, & &1.stop_sequence) == Enum.map(before_rows, & &1.stop_sequence)
      assert Enum.map(after_rows, & &1.departure_time) == ["05:00:00", "11:00:00"]

      updated = Repo.get!(Trip, trip.id)
      assert updated.trip_headsign == "Retimed"
      assert updated.block_id == "E-7"
      assert updated.trip_short_name == "9001"
      assert updated.wheelchair_accessible == 1
      assert updated.bikes_allowed == 2
      assert DateTime.compare(updated.updated_at, trip.updated_at) == :gt
    end

    test "a stale edit is refused with the reload copy and keeps the input", context do
      scope = editing_scope(context)
      {:ok, view, _html} = live(context.conn, schedules_path(scope))

      trip = trip_row(scope, "EDT_T0600")
      render_click(view, "open_edit_drawer", %{"trip" => trip.id})

      # Another editor saves the same trip first.
      assert {:ok, _changed} =
               Gtfs.update_trip(
                 "EDT1",
                 trip.id,
                 %{"trip_headsign" => "From the other session"},
                 Repo.get!(Trip, trip.id).updated_at,
                 audit_context(scope)
               )

      html =
        render_submit(view, "drawer_submit", %{
          "drawer" =>
            edit_params(scope, %{
              "trip_headsign" => "Typed but unsaved",
              "timed_pattern_id" => scope.long.timing.id,
              "start_time" => "06:00"
            })
        })

      assert html =~ "This trip changed since you opened it. Reload it to see the current values."
      assert html =~ ~s(id="trip-drawer-reload")
      assert html =~ "Typed but unsaved"
      refute html =~ ":stale"

      # The reload action re-opens the drawer with the row that is now stored.
      reloaded = render_click(view, "reload_drawer")
      assert reloaded =~ "From the other session"
      assert has_element?(view, "#trip-drawer[data-open='true']")
    end

    test "a failed save keeps every entry so the user can retry", context do
      scope = editing_scope(context)
      {:ok, view, _html} = live(context.conn, schedules_path(scope))

      trip = trip_row(scope, "EDT_T0600")
      render_click(view, "open_edit_drawer", %{"trip" => trip.id})

      html =
        render_submit(view, "drawer_submit", %{
          "drawer" =>
            edit_params(scope, %{
              "trip_headsign" => "Kept heading",
              "block_id" => "E-KEEP",
              "wheelchair_accessible" => "9"
            })
        })

      # The context changeset refused the enum; the drawer is still open with the
      # typed values, and nothing was written.
      assert has_element?(view, "#trip-drawer[data-open='true']")
      assert html =~ "Kept heading"
      assert html =~ "E-KEEP"
      assert html =~ ~s(id="trip-access-error")
      assert Repo.get!(Trip, trip.id).block_id == trip.block_id
    end

    test "a calendar change out of view says where the trip went", context do
      scope = editing_scope(context)
      {:ok, view, _html} = live(context.conn, schedules_path(scope))

      trip = trip_row(scope, "EDT_T0900")
      render_click(view, "open_edit_drawer", %{"trip" => trip.id})

      html =
        render_submit(view, "drawer_submit", %{
          "drawer" =>
            edit_params(scope, %{
              "service_id" => @saturday,
              "timed_pattern_id" => scope.long.timing.id,
              "start_time" => "09:00"
            })
        })

      assert html =~ "Moved to Saturday; it is no longer in this view."
      assert Repo.get!(Trip, trip.id).service_id == @saturday
      refute has_element?(view, "#trip-EDT_T0900-start")
    end

    test "the accessibility fields and the stable trip id sit behind a disclosure", context do
      scope = editing_scope(context)
      {:ok, view, _html} = live(context.conn, schedules_path(scope))

      trip = trip_row(scope, "EDT_T0600")
      html = render_click(view, "open_edit_drawer", %{"trip" => trip.id})

      assert html =~ ~s(id="trip-accessibility")
      assert html =~ "Accessibility and trip ID"
      assert html =~ ~s(id="trip-stable-id")
      assert html =~ "EDT_T0600"
      assert html =~ "This ID stays the same when you edit the trip."
      assert html =~ ~s(id="trip-block-list")
      assert html =~ ~s(value="E-1")
    end

    test "a custom trip shows its warning and only offers compatible timings", context do
      scope = editing_scope(context)
      {:ok, view, _html} = live(context.conn, schedules_path(scope))

      incompatible = trip_row(scope, "EDT_CUSTOM_DIFF")
      html = render_click(view, "open_edit_drawer", %{"trip" => incompatible.id})

      assert html =~ "This trip has custom stop times"
      assert html =~ "Keep custom times"
      assert html =~ "This trip's stops differ from the pattern, so its custom times are kept."
      # The incompatible choices are disabled with a visible reason.
      assert html =~ ~s(disabled="disabled")
      assert html =~ "This trip's stops differ from the pattern"
      # The departure field is disabled while the custom times are kept.
      assert has_element?(view, "#trip-start[disabled]")

      compatible = trip_row(scope, "EDT_CUSTOM_SAME")
      html = render_click(view, "open_edit_drawer", %{"trip" => compatible.id})

      assert html =~ "Use timing: Long time · 360 min total"
      refute has_element?(view, "#trip-start[disabled]")
    end

    test "a custom trip that adopts a timing is retimed and marked linked", context do
      scope = editing_scope(context)
      {:ok, view, _html} = live(context.conn, schedules_path(scope))

      compatible = trip_row(scope, "EDT_CUSTOM_SAME")
      render_click(view, "open_edit_drawer", %{"trip" => compatible.id})

      render_submit(view, "drawer_submit", %{
        "drawer" =>
          edit_params(scope, %{
            "timed_pattern_id" => scope.long.timing.id,
            "start_time" => "16:00",
            "service_id" => @weekday
          })
      })

      adopted = Repo.get!(Trip, compatible.id)
      assert adopted.pattern_derivation_state == "linked"
      assert adopted.timed_pattern_id == scope.long.timing.id

      assert Enum.map(stop_times(scope, "EDT_CUSTOM_SAME"), & &1.departure_time) ==
               ["16:00:00", "22:00:00"]
    end

    test "a frequency trip disables its departure and timing with visible reasons", context do
      scope = editing_scope(context)
      {:ok, view, _html} = live(context.conn, schedules_path(scope))

      frequency = trip_row(scope, "EDT_FREQ")
      html = render_click(view, "open_edit_drawer", %{"trip" => frequency.id})

      assert html =~ "Frequency window stays unchanged."
      assert html =~ "Frequency service has no single departure to edit."
      assert has_element?(view, "#trip-start[disabled]")
      refute has_element?(view, "#trip-timing")

      # The row menu disables Duplicate with the reason in visible text.
      assert has_element?(view, "#trip-EDT_FREQ-duplicate-disabled[disabled]")
      assert has_element?(view, "#trip-EDT_FREQ-duplicate-reason")
      assert render(view) =~ "Frequency service can't be duplicated"
      assert has_element?(view, "#trip-EDT_T0600-duplicate")
    end
  end

  describe "duplicate trip" do
    test "duplication takes the source start plus thirty minutes and one timing", context do
      scope = editing_scope(context)
      {:ok, view, _html} = live(context.conn, schedules_path(scope))

      source = trip_row(scope, "EDT_T0700")
      html = render_click(view, "open_duplicate_drawer", %{"trip" => source.id})

      assert html =~ "Duplicate trip"
      assert has_element?(view, "#trip-start")
      assert html =~ ~s(value="07:30")

      before = count_trips(scope)

      render_submit(view, "drawer_submit", %{
        "drawer" =>
          duplicate_params(scope, %{
            "start_time" => "07:30",
            "timed_pattern_id" => scope.long.timing.id
          })
      })

      assert count_trips(scope) == before + 1
      assert created_trip_ids(scope) == ["EDT1-0-EDT_WKD-0730"]

      [duplicate] =
        Repo.all(from(t in Trip, where: t.trip_id == "EDT1-0-EDT_WKD-0730"))

      assert duplicate.timed_pattern_id == scope.long.timing.id
      assert duplicate.block_id == "E-1"

      assert Enum.map(stop_times(scope, "EDT1-0-EDT_WKD-0730"), & &1.departure_time) ==
               ["07:30:00", "13:30:00"]

      # The source trip is untouched.
      assert Repo.get!(Trip, source.id).trip_id == "EDT_T0700"
    end

    test "a custom source is duplicated only with a timing chosen", context do
      scope = editing_scope(context)
      {:ok, view, _html} = live(context.conn, schedules_path(scope))

      source = trip_row(scope, "EDT_CUSTOM_DIFF")
      render_click(view, "open_duplicate_drawer", %{"trip" => source.id})

      before = count_trips(scope)

      html =
        render_submit(view, "drawer_submit", %{
          "drawer" =>
            duplicate_params(scope, %{"start_time" => "15:30", "timed_pattern_id" => "custom"})
        })

      assert html =~ "Choose a timing for the duplicated trip."
      assert count_trips(scope) == before
    end
  end

  describe "selection and delete" do
    test "the toolbar totals across sections and names the count and calendar", context do
      scope = editing_scope(context)
      {:ok, view, _html} = live(context.conn, schedules_path(scope))

      render_click(view, "toggle_trip", %{"trip" => trip_row(scope, "EDT_T0600").id})
      render_click(view, "toggle_trip", %{"trip" => trip_row(scope, "EDT_T0700").id})
      render_click(view, "toggle_trip", %{"trip" => trip_row(scope, "EDT_SHORT_1").id})

      assert has_element?(view, "#schedules-bulk-toolbar")
      assert render(view) =~ "3 trips selected"
      assert renders(view, "#schedules-delete-selected") =~ "Delete 3 trips"

      html = render_click(view, "delete_selected")

      assert html =~ "Delete 3 trips from Weekday?"
      assert html =~ "This removes the trips and their stop times from this published version."
      assert html =~ "You cannot undo this."
      assert has_element?(view, "#delete-dialog[data-open='true']")
    end

    test "a filter change clears the selection and a replayed delete deletes nothing", context do
      scope = editing_scope(context)
      {:ok, view, _html} = live(context.conn, schedules_path(scope))

      render_click(view, "toggle_trip", %{"trip" => trip_row(scope, "EDT_T0600").id})
      render_click(view, "toggle_trip", %{"trip" => trip_row(scope, "EDT_T0700").id})
      assert has_element?(view, "#schedules-bulk-toolbar")

      before = count_trips(scope)

      # A view change clears the selection, so the replayed event has nothing to
      # act on and no trip leaves the database.
      render_patch(view, schedules_path(scope, %{"service_id" => @weekday, "direction" => "1"}))
      refute has_element?(view, "#schedules-bulk-toolbar")

      render_click(view, "delete_selected")
      refute has_element?(view, "#delete-dialog[data-open='true']")
      assert count_trips(scope) == before
    end

    test "deleting a peak trip shows the vehicle change and it clears on a params change",
         context do
      scope = editing_scope(context)
      {:ok, view, _html} = live(context.conn, schedules_path(scope))

      assert renders(view, "#vehicles-needed-line") =~ "At least 6 vehicles"

      render_click(view, "toggle_trip", %{"trip" => trip_row(scope, "EDT_T1100").id})
      render_click(view, "delete_selected")
      render_click(view, "confirm_delete")

      assert renders(view, "#vehicle-change") =~ "6 → 5"
      assert renders(view, "#schedules-live-region") =~ "changed from 6 to 5"
      assert count_trips(scope, "EDT_T1100") == 0

      # A parameter change clears the marker.
      render_patch(view, schedules_path(scope, %{"service_id" => @weekday, "direction" => "1"}))
      refute renders(view, "#vehicle-change") =~ "→"
    end

    test "the single confirmation names the trip's start and pattern", context do
      scope = editing_scope(context)
      {:ok, view, _html} = live(context.conn, schedules_path(scope))

      render_click(view, "open_delete_trip", %{"trip" => trip_row(scope, "EDT_T0700").id})
      html = render(view)

      assert html =~ "Delete this trip?"
      assert html =~ "Departs 07:00 · Long pattern"
      assert has_element?(view, "#delete-dialog[data-open='true']")
      assert renders(view, "#delete-dialog-confirm") =~ "Delete 1 trip"
    end

    test "a delete failure keeps the confirmation open with the fixed copy", context do
      scope = editing_scope(context)
      {:ok, view, _html} = live(context.conn, schedules_path(scope))

      trip = trip_row(scope, "EDT_T0700")
      render_click(view, "open_delete_trip", %{"trip" => trip.id})

      # The trip moves to another calendar under the confirmation, so the list is
      # stale for this view and nothing is deleted.
      {:ok, _moved} =
        Gtfs.update_trip(
          "EDT1",
          trip.id,
          %{"service_id" => @saturday},
          Repo.get!(Trip, trip.id).updated_at,
          audit_context(scope)
        )

      html = render_click(view, "confirm_delete")

      assert html =~ ScheduleComponents.error_message(:stale)
      assert count_trips(scope, "EDT_T0700") == 1
    end
  end

  describe "error copy and states" do
    test "every error atom maps to fixed copy and no atom reaches the screen" do
      atoms = [
        :stale,
        :busy,
        :frequency_trip,
        :stops_differ,
        :timed_pattern_required,
        :not_found,
        :calendar_not_found,
        :trip_stop_times_mismatch,
        :trip_id_conflict,
        :invalid_time,
        :invalid_interval,
        :until_before_start,
        :too_many_trips,
        :invalid_input,
        :unauthorized
      ]

      assert ScheduleComponents.error_message(:busy) ==
               "Another change is being saved. Try again."

      assert ScheduleComponents.error_message(:stale) =~ "Reload it to see the current values."

      assert ScheduleComponents.error_message(:timed_pattern_required) ==
               "Choose a timing to change this trip's departure or stop times."

      copy = Enum.map(atoms, &ScheduleComponents.error_message/1)

      assert Enum.all?(copy, &is_binary/1)
      assert Enum.all?(copy, &(&1 =~ " "))
      refute Enum.any?(copy, &String.contains?(&1, ":"))

      # An unknown atom still shows a sentence, never the atom itself.
      assert ScheduleComponents.error_message(:something_new) ==
               ScheduleComponents.save_failure_copy()

      # The fixed create validation copy from the UI contracts.
      assert ScheduleComponents.error_message(:too_many_trips) =~ "Add 200 or fewer at a time"
    end

    test "the disconnected state disables Add and Save until reconnected", context do
      scope = editing_scope(context)
      {:ok, view, _html} = live(context.conn, schedules_path(scope))

      html = render(view)

      assert has_element?(view, "#schedules-disconnected[hidden]")
      assert html =~ ~s(phx-disconnected)

      add_button = renders(view, "#schedules-add-trips")
      assert add_button =~ ~s(phx-disconnected)
      assert add_button =~ ~s(phx-connected)

      render_click(view, "open_add_drawer")
      save = renders(view, "#trip-drawer-save")
      assert save =~ ~s(phx-disconnected)
      assert save =~ ~s(phx-connected)
    end

    test "closing a drawer or dialog returns focus to the invoking control", context do
      scope = editing_scope(context)
      {:ok, view, _html} = live(context.conn, schedules_path(scope))

      html = render_click(view, "open_add_drawer")
      assert html =~ ~s(data-return-focus-id="schedules-add-trips")

      render_click(view, "close_drawer")
      refute has_element?(view, "#trip-drawer[data-open='true']")

      trip = trip_row(scope, "EDT_T0600")
      html = render_click(view, "open_edit_drawer", %{"trip" => trip.id})
      assert html =~ ~s(data-return-focus-id="trip-EDT_T0600-edit")

      html = render_click(view, "open_delete_trip", %{"trip" => trip.id})
      assert html =~ ~s(data-return-focus-id="trip-EDT_T0600-menu")
    end
  end

  describe "production composition" do
    test "an add writes through the facade, the audit and the reload", context do
      scope = editing_scope(context)
      {:ok, view, _html} = live(context.conn, schedules_path(scope))
      open_add_drawer(view)

      render_submit(view, "drawer_submit", %{
        "drawer" => add_params(scope, %{"start_time" => "18:00"})
      })

      # The reloaded page shows the created trip, and the row exists in the
      # database with its stop times.
      assert has_element?(view, "#trip-EDT1-0-EDT_WKD-1800-start")

      assert [%Trip{} = created] =
               Repo.all(from(t in Trip, where: t.trip_id == "EDT1-0-EDT_WKD-1800"))

      assert created.pattern_derivation_state == "linked"
      assert created.route_pattern_id == scope.long.pattern.route_pattern_id
      assert length(Repo.all(from(s in StopTime, where: s.trip_id == ^created.trip_id))) == 2

      # One audit entry names the created trip.
      assert [log] =
               Repo.all(
                 from(l in GtfsPlanner.Gtfs.ChangeLog,
                   where: l.entity_type == "trip" and l.action == "created"
                 )
               )

      assert log.entity_external_id == "EDT1-0-EDT_WKD-1800"
    end

    test "an edit and a delete reload the page and the summary", context do
      scope = editing_scope(context)
      {:ok, view, _html} = live(context.conn, schedules_path(scope))

      trip = trip_row(scope, "EDT_T0800")
      render_click(view, "open_edit_drawer", %{"trip" => trip.id})

      render_submit(view, "drawer_submit", %{
        "drawer" =>
          edit_params(scope, %{
            "start_time" => "08:30",
            "timed_pattern_id" => scope.long.timing.id,
            "service_id" => @weekday
          })
      })

      assert has_element?(view, "#trip-EDT_T0800-start")
      assert Repo.get!(Trip, trip.id).updated_at != trip.updated_at

      render_click(view, "toggle_trip", %{"trip" => trip.id})
      render_click(view, "delete_selected")
      render_click(view, "confirm_delete")

      refute has_element?(view, "#trip-EDT_T0800-start")
      assert Repo.get(Trip, trip.id) == nil
      assert render(view) =~ "Deleted 1 trip"
    end
  end

  # --- scope fixtures --------------------------------------------------------

  defp editing_scope(context) do
    organization = context.organization
    organization_id = organization.id
    version = context.version

    route =
      route_fixture(organization_id, version.id, %{
        route_id: "EDT1",
        route_short_name: "E1",
        route_long_name: "Editing One"
      })

    _weekday = weekly_calendar(context, @weekday, "Weekday")
    _saturday = weekly_calendar(context, @saturday, "Saturday")

    Enum.each(1..3, fn index ->
      stop_fixture(organization_id, version.id, %{
        stop_id: "EDT_S#{index}",
        stop_name: "Editing Stop #{index}"
      })
    end)

    # Six hourly trips on a six-hour timing put the peak at 11:00 with six
    # vehicles, so deleting the 11:00 trip moves the marker to 5.
    long =
      schedule_pattern_fixture(organization_id, version.id, %{
        route_id: route.route_id,
        direction_id: 0,
        route_pattern_id: "EDT-P1",
        route_pattern_name: "Long pattern",
        route_pattern_typicality: 1,
        route_pattern_sort_order: 0,
        timing_name: "Long time",
        timing_headsign: "Editing outbound",
        stops: [{"EDT_S1", 0, 0, 1}, {"EDT_S2", 21_600, 21_600, 1}]
      })

    for {trip_id, start_time} <- [
          {"EDT_T0600", "06:00:00"},
          {"EDT_T0700", "07:00:00"},
          {"EDT_T0800", "08:00:00"},
          {"EDT_T0900", "09:00:00"},
          {"EDT_T1000", "10:00:00"},
          {"EDT_T1100", "11:00:00"}
        ] do
      schedule_trip_fixture(organization_id, version.id, route.route_id, long, %{
        service_id: @weekday,
        trip_id: trip_id,
        start_time: start_time,
        trip_headsign: "Editing outbound",
        block_id: "E-1"
      })
    end

    # A short second pattern gives the page two sections.
    short =
      schedule_pattern_fixture(organization_id, version.id, %{
        route_id: route.route_id,
        direction_id: 0,
        route_pattern_id: "EDT-P2",
        route_pattern_name: "Short pattern",
        route_pattern_typicality: 3,
        route_pattern_sort_order: 1,
        timing_name: "Short time",
        timing_headsign: "Editing short",
        stops: [{"EDT_S1", 0, 0, 1}, {"EDT_S2", 600, 600, 1}]
      })

    for {trip_id, start_time} <- [{"EDT_SHORT_1", "07:30:00"}, {"EDT_SHORT_2", "08:30:00"}] do
      schedule_trip_fixture(organization_id, version.id, route.route_id, short, %{
        service_id: @weekday,
        trip_id: trip_id,
        start_time: start_time,
        trip_headsign: "Editing short"
      })
    end

    schedule_trip_fixture(organization_id, version.id, route.route_id, short, %{
      service_id: @weekday,
      trip_id: "EDT_FREQ",
      start_time: "13:00:00",
      trip_headsign: "Editing short",
      frequencies: [%{start_time: "13:00:00", end_time: "14:00:00", headway_secs: 1200}]
    })

    # A custom trip whose stops differ from its pattern, and one that matches it.
    schedule_trip_fixture(organization_id, version.id, route.route_id, long, %{
      service_id: @weekday,
      trip_id: "EDT_CUSTOM_DIFF",
      state: "custom",
      timed_pattern_id: nil,
      trip_headsign: "Editing outbound",
      stop_times: [
        {"EDT_S1", "15:00:00", "15:00:00"},
        {"EDT_S3", "15:10:00", "15:10:00"}
      ]
    })

    schedule_trip_fixture(organization_id, version.id, route.route_id, long, %{
      service_id: @weekday,
      trip_id: "EDT_CUSTOM_SAME",
      state: "custom",
      timed_pattern_id: nil,
      trip_headsign: "Editing outbound",
      stop_times: [
        {"EDT_S1", "16:00:00", "16:00:00"},
        {"EDT_S2", "16:10:00", "16:10:00"}
      ]
    })

    back =
      schedule_pattern_fixture(organization_id, version.id, %{
        route_id: route.route_id,
        direction_id: 1,
        route_pattern_id: "EDT-P3",
        route_pattern_name: "Return pattern",
        route_pattern_typicality: 1,
        timing_name: "Return time",
        timing_headsign: "Editing inbound",
        stops: [{"EDT_S2", 0, 0, 1}, {"EDT_S1", 600, 600, 1}]
      })

    schedule_trip_fixture(organization_id, version.id, route.route_id, back, %{
      service_id: @weekday,
      trip_id: "EDT_BACK",
      start_time: "04:00:00",
      trip_headsign: "Editing inbound"
    })

    %{
      organization: organization,
      organization_id: organization_id,
      version: version,
      route: route,
      long: long,
      short: short,
      back: back
    }
  end

  defp weekly_calendar(context, service_id, name) do
    calendar_fixture(context.organization.id, context.version.id, %{service_id: service_id})

    calendar_attribute_fixture(context.organization.id, context.version.id, %{
      service_id: service_id,
      service_description: name,
      service_schedule_name: name
    })

    service_id
  end

  defp audit_context(scope) do
    %AuditContext{
      organization_id: scope.organization_id,
      gtfs_version_id: scope.version.id,
      station_stop_id: nil,
      actor_id: scope.user.id,
      actor_email: scope.user.email
    }
  end

  # --- page helpers ----------------------------------------------------------

  defp schedules_path(scope, query \\ %{}) do
    path = "/gtfs/#{scope.version.id}/routes/EDT1/schedules"

    case URI.encode_query(query) do
      "" -> path
      encoded -> path <> "?" <> encoded
    end
  end

  defp open_add_drawer(view) do
    render_click(view, "open_add_drawer")
    assert has_element?(view, "#trip-drawer[data-open='true']")
  end

  defp add_params(scope, overrides) do
    Map.merge(
      %{
        "pattern_id" => scope.long.pattern.id,
        "timed_pattern_id" => scope.long.timing.id,
        "service_id" => @weekday,
        "start_time" => "06:00",
        "repeat" => "false",
        "every" => "30",
        "until" => "09:00"
      },
      overrides
    )
  end

  defp edit_params(scope, overrides) do
    Map.merge(
      %{
        "pattern_id" => scope.long.pattern.id,
        "timed_pattern_id" => scope.long.timing.id,
        "service_id" => @weekday,
        "start_time" => "06:00",
        "trip_headsign" => "",
        "trip_short_name" => "",
        "block_id" => "",
        "wheelchair_accessible" => "0",
        "bikes_allowed" => "0"
      },
      overrides
    )
  end

  defp duplicate_params(scope, overrides) do
    Map.merge(
      %{
        "pattern_id" => scope.long.pattern.id,
        "timed_pattern_id" => scope.long.timing.id,
        "service_id" => @weekday,
        "start_time" => "07:30"
      },
      overrides
    )
  end

  defp renders(view, selector) do
    view |> element(selector) |> render()
  end

  # --- independent row assertions --------------------------------------------

  defp trip_row(scope, trip_id) do
    {:ok, schedule} =
      Gtfs.load_route_schedule(scope.organization_id, scope.version.id, "EDT1", %{
        "service_id" => @weekday
      })

    schedule.sections
    |> Enum.flat_map(& &1.rows)
    |> Enum.find(&(&1.trip_id == trip_id)) ||
      raise("no row for #{trip_id}; the fixture is wrong")
  end

  defp count_trips(scope, trip_id \\ nil) do
    query =
      from(t in Trip,
        where:
          t.organization_id == ^scope.organization_id and t.gtfs_version_id == ^scope.version.id
      )

    query = if trip_id, do: where(query, [t], t.trip_id == ^trip_id), else: query

    Repo.aggregate(query, :count)
  end

  defp created_trip_ids(scope) do
    Repo.all(
      from(t in Trip,
        where:
          t.organization_id == ^scope.organization_id and
            t.gtfs_version_id == ^scope.version.id and like(t.trip_id, "EDT1-0-EDT_WKD-0%"),
        select: t.trip_id,
        order_by: t.trip_id
      )
    )
  end

  defp stop_times(scope, trip_id) do
    Repo.all(
      from(s in StopTime,
        where:
          s.organization_id == ^scope.organization_id and
            s.gtfs_version_id == ^scope.version.id and s.trip_id == ^trip_id,
        order_by: [asc: s.stop_sequence, asc: s.id]
      )
    )
  end

  defp first_departures(scope, trip_ids) do
    Enum.map(trip_ids, fn trip_id ->
      scope
      |> stop_times(trip_id)
      |> List.first()
      |> Map.fetch!(:departure_time)
    end)
  end
end
