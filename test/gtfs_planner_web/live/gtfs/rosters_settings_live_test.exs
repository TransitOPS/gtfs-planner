defmodule GtfsPlannerWeb.Gtfs.RostersSettingsLiveTest do
  @moduledoc """
  The roster settings drawer: the base week, the two checks, and the fixed
  days-off rule.

  Every save here reaches the real writer — `Gtfs.update_roster_settings/2`
  through `RostersLive`'s `save_settings` — and the stored `blocking_settings`
  row is re-read through `Gtfs.get_roster_settings/2` afterwards, so "the scope
  bar says it" and "the database holds it" are two independent reads rather than
  one rendering.

  ## The world

  The operators suite's fixture (`rosters_operators_live_test.exs`): a weekday
  day type over Monday to Friday, plus Saturday and Sunday, with runs `2001`,
  `2002`, `2004`, `6001` and `7001`. A weekday day type is what gives the base
  week more than one option per weekday — the prototype's Weekdays + school /
  without school pair is the same shape — so the "most dates" marker and a real
  second choice are both reachable.

  ## What each case is really asserting

  - The rules the drawer edits are the composition's own `roster.rules`, so the
    drawer, the scope bar and the count strip cannot be showing two different
    sets of numbers (INV-15).
  - Validation happens on blur and on submit, and the errors are the writer's
    changeset — the page invents no rule of its own. 479 and 540 are the
    boundary's two sides: 479 is under the range and 540 is inside it.
  - A refused save writes nothing, which is asserted by re-reading the row.
  - A changed base week is the composition's own stale marking, so the slot's
    words come from `Roster.build/1` rather than from this page.
  - A stored day type that a calendar change has made unusable falls back, and
    the drawer says which day type replaced it rather than showing a blank or a
    silently different week (INV-6).
  """
  use GtfsPlannerWeb.ConnCase, async: false

  import Mox
  import Phoenix.LiveViewTest
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.BlockingFixtures
  import GtfsPlanner.RunsFixtures

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.Blocking
  alias GtfsPlanner.Gtfs.BlockingSetting
  alias GtfsPlanner.Repo

  setup :verify_on_exit!

  defp editor_setup(_context), do: %{user: user_fixture()}

  defp world do
    world = runs_version_fixture()

    # Every weekday flag is named: `calendar_service_fixture/3` fills the ones a
    # caller leaves out, so a Saturday calendar that named only `:saturday`
    # would also run Monday to Friday and the day types would merge into one.
    calendar_service_fixture(world.organization.id, world.version.id, %{
      service_id: "SAT",
      name: "Saturday",
      monday: 0,
      tuesday: 0,
      wednesday: 0,
      thursday: 0,
      friday: 0,
      saturday: 1,
      sunday: 0,
      start_date: ~D[2026-01-01],
      end_date: ~D[2026-12-31]
    })

    calendar_service_fixture(world.organization.id, world.version.id, %{
      service_id: "SUN",
      name: "Sunday",
      monday: 0,
      tuesday: 0,
      wednesday: 0,
      thursday: 0,
      friday: 0,
      saturday: 0,
      sunday: 1,
      start_date: ~D[2026-01-01],
      end_date: ~D[2026-12-31]
    })

    # A second weekday day type, so every weekday has a real second choice to
    # offer. It runs a shorter window than WK, so the combined service set is a
    # minority of Mondays and "Weekday" stays the default — which is what keeps
    # the existing weekday runs (2001, 2002, 2004) on their own day type.
    calendar_service_fixture(world.organization.id, world.version.id, %{
      service_id: "WKH",
      name: "Weekdays with a holiday",
      monday: 1,
      tuesday: 1,
      wednesday: 1,
      thursday: 1,
      friday: 0,
      saturday: 0,
      sunday: 0,
      start_date: ~D[2026-01-01],
      end_date: ~D[2026-03-31]
    })

    day_type_keys = day_type_keys(world)

    for {block_id, day_type_label, run_id, service} <- [
          {"201", "Weekday", "2001", "WK"},
          {"202", "Weekday", "2002", "WK"},
          {"204", "Weekday", "2004", "WK"},
          {"601", "Weekday + Weekdays with a holiday", "2601", "WKH"},
          {"401", "Saturday", "6001", "SAT"},
          {"501", "Sunday", "7001", "SUN"}
        ],
        {trip_id, first, last} <- block_trips(block_id),
        trip =
          blocked_trip_fixture(world.organization.id, world.version.id, world.route.route_id, %{
            trip_id: trip_id,
            service_id: service,
            block_id: block_id,
            first_arrival: first,
            last_arrival: last
          }) do
      trip_run_fixture(world.organization.id, world.version.id, %{
        trip: trip,
        day_type_key: Map.fetch!(day_type_keys, day_type_label),
        run_id: run_id
      })
    end

    world
  end

  defp day_type_keys(world) do
    {:ok, day} = Blocking.load_day(world.organization.id, world.version.id, nil)

    Map.new(day.day_types, fn day_type -> {day_type.label, day_type.key} end)
  end

  defp block_trips("201"),
    do: [
      {"w201a", "05:50:00", "06:50:00"},
      {"w201b", "07:00:00", "08:00:00"},
      {"w201c", "09:00:00", "13:00:00"},
      {"w201d", "13:30:00", "15:30:00"}
    ]

  defp block_trips("202"),
    do: [{"w202a", "12:00:00", "12:30:00"}, {"w202b", "12:40:00", "13:10:00"}]

  defp block_trips("204"),
    do: [{"w204a", "22:30:00", "23:00:00"}, {"w204b", "23:45:00", "00:45:00"}]

  defp block_trips("601"),
    do: [{"w601a", "08:10:00", "08:40:00"}, {"w601b", "08:50:00", "09:20:00"}]

  defp block_trips("401"),
    do: [{"w401a", "07:00:00", "07:30:00"}, {"w401b", "07:45:00", "08:15:00"}]

  defp block_trips("501"),
    do: [{"w501a", "20:00:00", "20:30:00"}, {"w501b", "20:45:00", "21:15:00"}]

  defp signed_in(context) do
    world = world()

    {:ok, _membership} =
      Accounts.create_user_org_membership(%{
        user_id: context.user.id,
        organization_id: world.organization.id,
        roles: ["pathways_studio_editor"]
      })

    {log_in_user(context.conn, context.user, organization: world.organization), world}
  end

  defp path(world), do: "/gtfs/#{world.version.id}/rosters"

  defp text_of(view, selector) do
    view
    |> render()
    |> LazyHTML.from_document()
    |> LazyHTML.query(selector)
    |> LazyHTML.text()
    |> String.trim()
  end

  # The same, with the template's own line breaks collapsed to single spaces, so
  # a sentence can be asserted as one sentence rather than as the indentation it
  # happens to be written with.
  defp squish(view, selector) do
    view
    |> text_of(selector)
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
  end

  defp attribute(view, selector, name) do
    view
    |> render()
    |> LazyHTML.from_document()
    |> LazyHTML.query(selector)
    |> LazyHTML.attribute(name)
    |> List.first()
  end

  defp select_options(view, selector) do
    view
    |> render()
    |> LazyHTML.from_document()
    |> LazyHTML.query(selector <> " option")
    |> Enum.map(fn option ->
      {
        String.trim(LazyHTML.text(option)),
        LazyHTML.attribute(option, "value") |> List.first() |> to_string(),
        LazyHTML.attribute(option, "selected") != []
      }
    end)
  end

  # The stored row, re-read. Defaults are the researched ones when nothing has
  # been saved, so a refusal shows up here as the default still being stored.
  defp stored_settings(world),
    do: Gtfs.get_roster_settings(world.organization.id, world.version.id)

  defp day_type_key(world, label) do
    {:ok, day} = Blocking.load_day(world.organization.id, world.version.id, nil)

    Enum.find_value(day.day_types, fn day_type ->
      if day_type.label == label, do: day_type.key
    end)
  end

  # Each day type's count of dates on one weekday, read from the same day load
  # the drawer derived its option labels from.
  defp dates_by_weekday(world, weekday) do
    {:ok, day} = Blocking.load_day(world.organization.id, world.version.id, nil)

    Map.new(day.day_types, fn day_type ->
      {day_type.label, Enum.count(day_type.dates, &(Date.day_of_week(&1) == weekday))}
    end)
  end

  # A stored day type a calendar change has since made unusable, written past
  # the writer. The writer is right to refuse it — that is what the refusals in
  # `roster_settings_test.exs` assert — so this state cannot be reached through
  # `update_roster_settings/2` and is written the only way it can be reached in
  # production: a save that was correct when it was made, against calendars
  # that have changed since.
  defp store_unusable_day_type(world, weekday, key) do
    changeset =
      BlockingSetting.roster_changeset(
        %BlockingSetting{
          organization_id: world.organization.id,
          gtfs_version_id: world.version.id
        },
        %{"roster_day_types" => %{Integer.to_string(weekday) => key}}
      )

    {:ok, _saved} =
      Repo.insert(changeset,
        on_conflict: {:replace, [:roster_day_types, :updated_at]},
        conflict_target: [:organization_id, :gtfs_version_id]
      )
  end

  defp line(world, days) do
    {:ok, %{id: line_id}} = Gtfs.create_roster_line(world_audit(world))

    for {weekday, run_id} <- days do
      assert {:ok, _result} =
               Gtfs.set_roster_slot(
                 world_audit(world),
                 line_id,
                 weekday,
                 run_id
               )
    end

    line_id
  end

  defp line_number(world, line_id) do
    {:ok, %{roster: roster}} = Gtfs.load_roster(world.organization.id, world.version.id)

    Enum.find_value(roster.lines, fn built ->
      if built.id == line_id, do: built.line_number
    end)
  end

  # The form with the numbers the caller is testing, and every other control the
  # drawer is showing. `form/3` is given the weekday selects' current values as
  # well as the numbers, because a submit carries every control in the form: a
  # submit that named only the numbers would drop the base week.
  defp settings_form(view, rest, weekly_hours_warn_above) do
    settings =
      base_params(view)
      |> Map.merge(rest)
      |> Map.put("weekly_hours_warn_above", weekly_hours_warn_above)

    form(view, "#rosters-settings-form", settings: settings)
  end

  # What the drawer currently holds, read off the DOM: the numbers and the seven
  # weekday selects as they are drawn. Reusing the drawn values is what makes a
  # submit a real submit rather than a hand-built one that replaces the base week
  # with a partial map.
  # Every value the drawer is currently showing, read back out of its own rendered
  # controls. A save test that starts from these cannot fail for a reason the
  # planner would not see, and a weekday with no select simply has no entry.
  defp base_params(view) do
    html = render(view)

    days =
      for weekday <- 1..7,
          key = select_value(html, "#rosters-settings-base-#{weekday}"),
          is_binary(key),
          do: {Integer.to_string(weekday), key}

    %{
      "min_rest_minutes" => input_value(html, "#rosters-settings-rest"),
      "weekly_hours_warn_above" => input_value(html, "#rosters-settings-warn"),
      "roster_day_types" => Map.new(days)
    }
  end

  defp input_value(html, selector) do
    html
    |> LazyHTML.from_document()
    |> LazyHTML.query(selector)
    |> LazyHTML.attribute("value")
    |> List.first()
  end

  defp select_value(html, selector) do
    html
    |> LazyHTML.from_document()
    |> LazyHTML.query(selector <> " option[selected]")
    |> LazyHTML.attribute("value")
    |> List.first()
  end

  describe "opening the drawer" do
    setup :editor_setup

    test "the scope button opens it with one select per weekday", context do
      {conn, world} = signed_in(context)
      {:ok, view, _html} = live(conn, path(world))

      # The button states the rules in use before the drawer is open, so the
      # values a planner is about to change are already on screen.
      assert text_of(view, "#rosters-settings-button") =~ "rest 10 h"
      assert text_of(view, "#rosters-settings-button") =~ "warn above 48 h"

      view |> element("#rosters-settings-button") |> render_click()

      assert has_element?(view, "#rosters-settings-drawer")
      assert has_element?(view, "#rosters-settings-form")
      assert text_of(view, "#rosters-settings-lede") =~ "This version"
      assert text_of(view, "#rosters-settings-lede") =~ "every line"

      # One select per weekday that a day type dates, each labelled with the day
      # it decides and offered only the day types that run on it.
      for weekday <- 1..7 do
        assert has_element?(view, "#rosters-settings-base-#{weekday}")
        assert has_element?(view, "#rosters-settings-base-label-#{weekday}")
      end

      weekday_labels =
        view |> select_options("#rosters-settings-base-1") |> Enum.map(&elem(&1, 0))

      # Each weekday offers every day type that runs on it, with the dates each
      # has there. The counts are read from the same day load the drawer derived
      # them from, so this asserts the drawer agreeing with the composition
      # rather than a number typed twice.
      monday_counts = dates_by_weekday(world, 1)
      combined = monday_counts["Weekday + Weekdays with a holiday"]

      assert Enum.any?(weekday_labels, &(&1 =~ "Weekday · #{monday_counts["Weekday"]} Mondays"))

      assert Enum.any?(weekday_labels, &(&1 =~ "Weekdays with a holiday · #{combined} Mondays"))

      # The default is marked because nothing is stored yet and the week in use
      # came from the fallback. The marker sits on the option, not the control.
      assert view
             |> select_options("#rosters-settings-base-1")
             |> Enum.any?(fn {_label, _key, _sel} = option ->
               option |> elem(0) |> String.contains?("(most dates)")
             end)

      # Saturday and Sunday each have one day type and one option, and it is
      # still the default, so it carries the marker: the marker says which option
      # is in use, and here that is a fact worth saying.
      saturday_counts = dates_by_weekday(world, 6)
      sunday_counts = dates_by_weekday(world, 7)

      assert select_options(view, "#rosters-settings-base-6") |> Enum.map(&elem(&1, 0)) == [
               "Saturday · #{saturday_counts["Saturday"]} Saturdays (most dates)"
             ]

      assert select_options(view, "#rosters-settings-base-7") |> Enum.map(&elem(&1, 0)) == [
               "Sunday · #{sunday_counts["Sunday"]} Sundays (most dates)"
             ]

      # The selected option is the day type the grid is already working with,
      # so the drawer opens on the week the page shows.
      selected =
        view
        |> select_options("#rosters-settings-base-1")
        |> Enum.filter(&elem(&1, 2))
        |> Enum.map(&elem(&1, 1))

      assert selected == [day_type_key(world, "Weekday")]

      # Exactly one option is selected, so the control is never ambiguous about
      # which day type is in use for that weekday.
      chosen =
        view
        |> select_options("#rosters-settings-base-1")
        |> Enum.count(fn {_label, _key, selected?} -> selected? end)

      assert chosen == 1
    end

    test "the days-off rule is text and both numbers show the stored values", context do
      {conn, world} = signed_in(context)
      {:ok, view, _html} = live(conn, path(world))

      view |> element("#rosters-settings-button") |> render_click()

      assert attribute(view, "#rosters-settings-rest", "value") == "600"
      assert attribute(view, "#rosters-settings-warn", "value") == "48"

      # The days-off rule is fixed (AC-15), so it is drawn as the rule reads
      # rather than as a control that looks editable and is not.
      days_off = squish(view, "#rosters-settings-days-off")
      assert days_off =~ "At least two days off in a row each week"
      assert days_off =~ "Sunday → Monday"
      assert days_off =~ "Shown as a warning"
      assert days_off =~ "Fixed"
      refute has_element?(view, "#rosters-settings-days-off input")
    end

    test "Cancel closes it and writes nothing", context do
      {conn, world} = signed_in(context)
      {:ok, view, _html} = live(conn, path(world))

      view |> element("#rosters-settings-button") |> render_click()
      assert has_element?(view, "#rosters-settings-drawer")

      view |> element("#rosters-settings-cancel") |> render_click()

      refute has_element?(view, "#rosters-settings-drawer")
      assert stored_settings(world) == defaults()
    end

    test "a stored day type a calendar change made unusable names the fallback", context do
      {conn, world} = signed_in(context)
      saturday_key = day_type_key(world, "Saturday")

      # A stored Saturday choice for Monday: a real day type with no Monday date,
      # which is exactly what `BaseWeek` falls back from and reports.
      store_unusable_day_type(world, 1, saturday_key)

      {:ok, view, _html} = live(conn, path(world))
      view |> element("#rosters-settings-button") |> render_click()

      # The notice names the day type Monday fell back *to*, and the lost key, so
      # a fallback is never silent (INV-6). Both are `BaseWeek`'s own answer, so
      # they are read from the composition rather than typed here.
      {:ok, %{roster: roster}} = Gtfs.load_roster(world.organization.id, world.version.id)
      monday = Map.fetch!(roster.base_week, 1)

      notice = squish(view, "#rosters-settings-base-missing")
      assert notice =~ "Monday now uses #{monday.day_type.label}, not #{saturday_key}"
      assert monday.missing_choice == saturday_key

      # The select shows the day type actually in use rather than a key that
      # cannot be chosen, and the notice above is what says a stored choice was
      # lost — so a fallback is visible rather than silent (INV-6).
      selected =
        view
        |> select_options("#rosters-settings-base-1")
        |> Enum.filter(&elem(&1, 2))
        |> Enum.map(&elem(&1, 1))

      assert selected == [monday.day_type.key]
    end
  end

  describe "validating" do
    setup :editor_setup

    test "479 shows the range error on blur, and nothing else is marked", context do
      {conn, world} = signed_in(context)
      {:ok, view, _html} = live(conn, path(world))

      view |> element("#rosters-settings-button") |> render_click()

      render_change(view, "validate_settings", %{
        "settings" => %{"min_rest_minutes" => "479", "weekly_hours_warn_above" => "48"},
        "_target" => ["settings", "min_rest_minutes"]
      })

      assert has_element?(view, "#rosters-settings-rest[aria-invalid='true']")
      assert text_of(view, "#rosters-settings-rest-error") =~ "between 480 and 720"
      # The weekly hours field is untouched, so it is not marked: a reader is
      # not told about a field they have not finished.
      refute has_element?(view, "#rosters-settings-warn[aria-invalid='true']")
    end

    test "479 on submit is refused, focused and writes nothing", context do
      {conn, world} = signed_in(context)
      {:ok, view, _html} = live(conn, path(world))

      view |> element("#rosters-settings-button") |> render_click()

      view
      |> settings_form(%{"min_rest_minutes" => "479"}, "48")
      |> render_submit()

      assert has_element?(view, "#rosters-settings-errors")
      summary = text_of(view, "#rosters-settings-errors")
      assert summary =~ "Fix these to save the settings"
      assert summary =~ "Minimum rest: must be a whole number between 480 and 720"

      assert_push_event(view, "focus_form_error", %{
        form_id: "rosters-settings-form",
        fallback_id: "rosters-settings-errors"
      })

      # The drawer stays open with what was typed, and the row is untouched: a
      # refusal that closes the drawer reads as lost work.
      assert has_element?(view, "#rosters-settings-drawer")
      assert attribute(view, "#rosters-settings-rest", "value") == "479"
      assert stored_settings(world) == defaults()
    end

    test "a weekly hours value out of range is refused on the same terms", context do
      {conn, world} = signed_in(context)
      {:ok, view, _html} = live(conn, path(world))

      view |> element("#rosters-settings-button") |> render_click()

      view
      |> settings_form(%{"min_rest_minutes" => "600"}, "61")
      |> render_submit()

      assert has_element?(view, "#rosters-settings-warn[aria-invalid='true']")
      assert text_of(view, "#rosters-settings-warn-error") =~ "between 40 and 60"
      assert stored_settings(world) == defaults()
    end

    test "a base-week choice the writer refuses is refused with the writer's sentence", context do
      {conn, world} = signed_in(context)

      {:ok, view, _html} = live(conn, path(world))
      view |> element("#rosters-settings-button") |> render_click()

      # A key the version does not derive cannot be typed into a select, so this
      # is the hand-built event: it must still reach the writer and be refused
      # by it, with the drawer's summary naming the field. The keys for the other
      # weekdays come from the drawer, so the refusal is about this one entry
      # and not about a map the test invented.
      render_submit(view, "save_settings", %{
        "settings" => %{
          "min_rest_minutes" => "600",
          "weekly_hours_warn_above" => "48",
          "roster_day_types" =>
            Map.put(base_params(view)["roster_day_types"], "1", "no-such-day-type")
        }
      })

      assert has_element?(view, "#rosters-settings-drawer")
      assert text_of(view, "#rosters-settings-errors") =~ "Base week: "
      assert stored_settings(world) == defaults()
    end

    test "a submit with no drawer open is not a write", context do
      {conn, world} = signed_in(context)
      {:ok, view, _html} = live(conn, path(world))

      render_submit(view, "save_settings", %{
        "settings" => %{
          "min_rest_minutes" => "540",
          "weekly_hours_warn_above" => "48",
          "roster_day_types" => %{"1" => day_type_key(world, "Weekday")}
        }
      })

      refute has_element?(view, "#rosters-settings-drawer")
      assert stored_settings(world) == defaults()
    end
  end

  describe "saving" do
    setup :editor_setup

    test "a valid save stores 540 and the scope button says so", context do
      {conn, world} = signed_in(context)
      {:ok, view, _html} = live(conn, path(world))

      view |> element("#rosters-settings-button") |> render_click()

      view
      |> settings_form(%{"min_rest_minutes" => "540"}, "48")
      |> render_submit()

      # Re-read from the table rather than trusted from the page.
      assert stored_settings(world).min_rest_minutes == 540

      # The scope bar is the composition's own figure, so it changed because the
      # stored rule did.
      assert text_of(view, "#rosters-settings-button") =~ "rest 9 h"

      # The drawer closed and the toast says what the save did.
      refute has_element?(view, "#rosters-settings-drawer")
      assert text_of(view, "#rosters-toast-text") =~ "Roster settings saved"
    end

    test "a saved base week is stored, re-read and reported by the scope bar", context do
      {conn, world} = signed_in(context)
      holiday_key = day_type_key(world, "Weekday + Weekdays with a holiday")
      weekday_key = day_type_key(world, "Weekday")

      {:ok, view, _html} = live(conn, path(world))
      view |> element("#rosters-settings-button") |> render_click()

      # Submit the drawer's own values with Monday through Wednesday moved onto
      # the holiday day type. Every select is submitted, so the stored map has
      # one entry per weekday — a save is the whole week, never a patch to it.
      params = base_params(view)

      params = put_in(params, ["roster_day_types", "1"], holiday_key)
      params = put_in(params, ["roster_day_types", "2"], holiday_key)
      params = put_in(params, ["roster_day_types", "3"], holiday_key)

      view
      |> form("#rosters-settings-form", settings: params)
      |> render_submit()

      assert stored_settings(world).roster_day_types == %{
               "1" => holiday_key,
               "2" => holiday_key,
               "3" => holiday_key,
               "4" => weekday_key,
               "5" => weekday_key,
               "6" => day_type_key(world, "Saturday"),
               "7" => day_type_key(world, "Sunday")
             }

      # Monday through Wednesday now run on the holiday day type and Thursday
      # and Friday still on the weekday one, so the scope bar reports the week as
      # those two groups rather than as one weekday run. The bar is the
      # composition's own wording, quoted from it rather than invented here.
      scope = squish(view, "#rosters-scope")
      assert scope =~ "Mon–Wed Weekday + Weekdays with a holiday"
      assert scope =~ "Thu–Fri Weekday"
    end

    test "changing Monday's base marks the existing Monday slots Base week changed", context do
      {conn, world} = signed_in(context)
      holiday_key = day_type_key(world, "Weekday + Weekdays with a holiday")

      line_id = line(world, [{1, "2001"}, {2, "2002"}])
      number = line_number(world, line_id)

      {:ok, view, _html} = live(conn, path(world))
      assert has_element?(view, "#rosters-grid", "2001")

      view |> element("#rosters-settings-button") |> render_click()

      params =
        view
        |> base_params()
        |> put_in(["roster_day_types", "1"], holiday_key)

      view
      |> form("#rosters-settings-form", settings: params)
      |> render_submit()

      # The marking is the composition's own stale reason, not a message this
      # page wrote: the stored slot's day type is no longer Monday's base.
      assert stored_settings(world).roster_day_types["1"] == holiday_key

      assert text_of(view, "#rosters-grid") =~ "Base week changed"
      assert text_of(view, "#slot-#{number}-1") =~ "Stale run"

      # Re-read: the slot row itself reports the stale reason, so this is the
      # composition's answer rather than a string the grid drew for the test.
      {:ok, %{roster: roster}} = Gtfs.load_roster(world.organization.id, world.version.id)
      composed = Enum.find(roster.lines, &(&1.id == line_id))

      assert %{state: {:stale, :base_changed}} = Map.fetch!(composed.slots, 1)
      assert %{state: :ok} = Map.fetch!(composed.slots, 2)
    end

    test "the crew rules and Block rules survive a roster settings save", context do
      {conn, world} = signed_in(context)

      {:ok, _crew} =
        Gtfs.update_crew_settings(world.audit, %{
          "max_piece_minutes" => 300,
          "report_pull_out_minutes" => 20,
          "report_relief_minutes" => 6,
          "sign_off_minutes" => 6,
          "paid_break_max_minutes" => 30
        })

      before = Gtfs.get_crew_settings(world.organization.id, world.version.id)
      blocking_before = Gtfs.get_blocking_settings(world.organization.id, world.version.id)

      {:ok, view, _html} = live(conn, path(world))
      view |> element("#rosters-settings-button") |> render_click()

      view
      |> settings_form(%{"min_rest_minutes" => "660"}, "52")
      |> render_submit()

      assert stored_settings(world).min_rest_minutes == 660
      assert stored_settings(world).weekly_hours_warn_above == 52

      # A roster-settings write replaces only the three roster columns, so the
      # rules the other two pages own are still what they were.
      assert Gtfs.get_crew_settings(world.organization.id, world.version.id) == before

      assert Gtfs.get_blocking_settings(world.organization.id, world.version.id) ==
               blocking_before
    end
  end

  defp defaults, do: %{min_rest_minutes: 600, weekly_hours_warn_above: 48, roster_day_types: %{}}
end
