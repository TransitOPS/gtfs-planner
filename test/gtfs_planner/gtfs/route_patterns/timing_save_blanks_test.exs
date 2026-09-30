defmodule GtfsPlanner.Gtfs.RoutePatterns.TimingSaveBlanksTest do
  @moduledoc """
  The Running times save accepts a blank arrival and departure at a non-timepoint
  stop between the two ends, and refuses one anywhere else.

  A blank is the absence of a scheduled time, not `0` and not an estimate, so the
  editor may clear both cells of an interior non-timepoint row and the context
  stores a nil offset pair. The first and last stops always publish a time and a
  `timepoint = 1` stop always does, so clearing either of those is an inline
  error naming the stop, and clearing only one of the two cells is a half pair
  the timing rule refuses. The context reaches that decision through
  `TimingRules.validate/1`, like derivation, the materializer and stop review.

  Expected offsets, reasons and messages are literals from the GTFS reference
  (an interpolated time is absent, `timepoint = 1` carries a time), the prepared
  step 6 cases and the MBTA route_patterns documentation. No production function
  computes an expected value here.
  """

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
  alias GtfsPlanner.Gtfs.RoutePatternStop
  alias GtfsPlanner.Gtfs.StopTime
  alias GtfsPlanner.Gtfs.TimedPatternStop
  alias GtfsPlanner.Repo

  describe "a context timing save" do
    test "blanks at the interior non-timepoint rows succeed and store nil offsets", context do
      bundle = four_stop_pattern(context, suffix: "SAVE1")

      assert {:ok, %{fingerprint: fingerprint}} =
               Gtfs.review(
                 bundle.pattern.id,
                 {:timing, bundle.timing.id, %{rows: blanked(bundle)}},
                 nil,
                 context.audit
               )

      assert {:ok, %{trips_updated: 1}} =
               Gtfs.apply_review(
                 bundle.pattern.id,
                 {:timing, bundle.timing.id, %{rows: blanked(bundle)}},
                 fingerprint,
                 context.audit
               )

      assert bundle |> timing_offsets() == [
               {0, 0},
               {nil, nil},
               {nil, nil},
               {900, 900}
             ]

      # The blank reaches the linked trip's stop_times as the absence of a time,
      # not as a clock value invented from the neighbouring rows.
      assert Enum.map(stop_times(bundle.trip.trip_id), &{&1.stop_id, &1.arrival_time}) == [
               {"SAVE1_S1", "07:00:00"},
               {"SAVE1_S2", nil},
               {"SAVE1_S3", nil},
               {"SAVE1_S4", "07:15:00"}
             ]
    end

    test "a blank on the last row is refused and names the position", context do
      bundle = four_stop_pattern(context, suffix: "SAVE2")
      rows = [%{row(bundle, 0) | arrival_offset: nil, departure_offset: nil} | row_tail(bundle)]

      assert {:error, :explicit_terminal_values_required} =
               Gtfs.review(
                 bundle.pattern.id,
                 {:timing, bundle.timing.id, %{rows: rows}},
                 nil,
                 context.audit
               )

      assert bundle |> timing_offsets() == [{0, 0}, {240, 300}, {600, 660}, {900, 900}]
    end

    test "a blank on a timepoint row is refused", context do
      bundle = four_stop_pattern(context, suffix: "SAVE3")
      [_, second | _] = occurrences(bundle)

      rows = [
        row(bundle, 0),
        %{row(bundle, 1) | arrival_offset: nil, departure_offset: nil, timepoint: 1},
        row(bundle, 2),
        row(bundle, 3)
      ]

      set_timepoint(bundle.timing.id, second.id, 1)

      # A `timepoint = 1` stop always publishes a time, so a blank there breaks
      # the timing rule's timepoint case and nothing is written.
      assert {:error, :invalid_chronology} =
               Gtfs.review(
                 bundle.pattern.id,
                 {:timing, bundle.timing.id, %{rows: rows}},
                 nil,
                 context.audit
               )

      assert timing_offsets(bundle) == [{0, 0}, {240, 300}, {600, 660}, {900, 900}]
      assert timepoint(bundle.timing.id, second.id) == 1
    end

    test "a half row is refused and nothing is written", context do
      bundle = four_stop_pattern(context, suffix: "SAVE4")

      rows = [
        row(bundle, 0),
        %{row(bundle, 1) | arrival_offset: nil, departure_offset: 300},
        row(bundle, 2),
        row(bundle, 3)
      ]

      assert {:error, :invalid_time} =
               Gtfs.review(
                 bundle.pattern.id,
                 {:timing, bundle.timing.id, %{rows: rows}},
                 nil,
                 context.audit
               )

      assert timing_offsets(bundle) == [{0, 0}, {240, 300}, {600, 660}, {900, 900}]
    end

    test "a blank input string from the editor is read as a blank, not as a value", context do
      bundle = four_stop_pattern(context, suffix: "SAVE5")

      rows = [
        row(bundle, 0),
        %{row(bundle, 1) | arrival_offset: "", departure_offset: ""},
        row(bundle, 2),
        row(bundle, 3)
      ]

      assert {:ok, %{fingerprint: fingerprint, proposed: %{rows: [_, second | _]}}} =
               Gtfs.review(
                 bundle.pattern.id,
                 {:timing, bundle.timing.id, %{rows: rows}},
                 nil,
                 context.audit
               )

      # The empty cells are read as the absence of a time, not as a value that
      # fails the shape check.
      assert second.arrival_offset == nil
      assert second.departure_offset == nil

      assert {:ok, _applied} =
               Gtfs.apply_review(
                 bundle.pattern.id,
                 {:timing, bundle.timing.id, %{rows: rows}},
                 fingerprint,
                 context.audit
               )

      assert timing_offsets(bundle) == [{0, 0}, {nil, nil}, {600, 660}, {900, 900}]
    end

    test "a first departure that is not the base is still refused", context do
      bundle = four_stop_pattern(context, suffix: "SAVE6")

      rows = [%{row(bundle, 0) | departure_offset: 60} | row_tail(bundle)]

      assert {:error, :first_departure_must_be_zero} =
               Gtfs.review(
                 bundle.pattern.id,
                 {:timing, bundle.timing.id, %{rows: rows}},
                 nil,
                 context.audit
               )

      assert timing_offsets(bundle) == [{0, 0}, {240, 300}, {600, 660}, {900, 900}]
    end
  end

  describe "the timing editor" do
    setup :editor_scope

    test "clearing an interior non-timepoint row saves the blank and shows no error",
         context do
      %{conn: conn, version: version} = context
      bundle = four_stop_pattern(context, linked: false, suffix: "SAVE7")

      {:ok, view, _html} =
        live(conn, pattern_path(version, bundle.route, bundle.pattern, "?task=timings"))

      edit_timing_field(view, 2, "arrival", "")
      edit_timing_field(view, 2, "departure", "")

      refute has_element?(view, "#timing-departure-2[aria-invalid='true']")

      render_click(view, "save_timing")

      assert has_element?(view, "#status", "Changes saved")
      refute has_element?(view, "#timing-arrival-2[aria-invalid='true']")
      assert timing_offsets(bundle) == [{0, 0}, {nil, nil}, {600, 660}, {900, 900}]
      assert has_element?(view, "#timing-arrival-2[value='']")
      assert has_element?(view, "#timing-departure-2[value='']")
    end

    test "clearing the last stop's cells names that stop and writes nothing",
         context do
      %{conn: conn, version: version} = context
      bundle = four_stop_pattern(context, linked: false, suffix: "SAVE8")

      {:ok, view, _html} =
        live(conn, pattern_path(version, bundle.route, bundle.pattern, "?task=timings"))

      edit_timing_field(view, 4, "arrival", "")
      edit_timing_field(view, 4, "departure", "")
      render_click(view, "save_timing")

      assert has_element?(view, "#timing-error-4", "needs arrival and departure times")
      assert has_element?(view, "#error", "needs arrival and departure times")
      assert has_element?(view, "#timing-arrival-4[aria-invalid='true']")
      assert timing_offsets(bundle) == [{0, 0}, {240, 300}, {600, 660}, {900, 900}]
    end

    test "clearing the first stop's cells names that stop and writes nothing",
         context do
      %{conn: conn, version: version} = context
      bundle = four_stop_pattern(context, linked: false, suffix: "SAVE9")

      {:ok, view, _html} =
        live(conn, pattern_path(version, bundle.route, bundle.pattern, "?task=timings"))

      edit_timing_field(view, 1, "arrival", "")
      edit_timing_field(view, 1, "departure", "")
      render_click(view, "save_timing")

      assert has_element?(view, "#timing-error-1", "needs arrival and departure times")
      assert timing_offsets(bundle) == [{0, 0}, {240, 300}, {600, 660}, {900, 900}]
    end

    test "clearing only the departure of an interior row is a half pair and is refused",
         context do
      %{conn: conn, version: version} = context
      bundle = four_stop_pattern(context, linked: false, suffix: "SAVE10")

      {:ok, view, _html} =
        live(conn, pattern_path(version, bundle.route, bundle.pattern, "?task=timings"))

      edit_timing_field(view, 2, "departure", "")
      render_click(view, "save_timing")

      assert has_element?(view, "#timing-error-2", "needs arrival and departure times")
      assert has_element?(view, "#timing-departure-2[aria-invalid='true']")
      assert timing_offsets(bundle) == [{0, 0}, {240, 300}, {600, 660}, {900, 900}]
    end

    test "a row after a blank compares against the last timed departure",
         context do
      %{conn: conn, version: version} = context
      bundle = four_stop_pattern(context, linked: false, suffix: "SAVE11")

      {:ok, view, _html} =
        live(conn, pattern_path(version, bundle.route, bundle.pattern, "?task=timings"))

      edit_timing_field(view, 2, "arrival", "")
      edit_timing_field(view, 2, "departure", "")

      # Row 1's departure is the last timed departure before row 3, so 05:00 is
      # still in order with row 2 blank between them.
      edit_timing_field(view, 3, "arrival", "05:00")
      edit_timing_field(view, 3, "departure", "05:30")
      render_click(view, "save_timing")

      refute has_element?(view, "#timing-arrival-3[aria-invalid='true']")
      assert has_element?(view, "#status", "Changes saved")
      assert timing_offsets(bundle) == [{0, 0}, {nil, nil}, {300, 330}, {900, 900}]
    end

    test "a timed row after a blank that goes backwards is still refused",
         context do
      %{conn: conn, version: version} = context
      bundle = four_stop_pattern(context, linked: false, suffix: "SAVE12")

      {:ok, view, _html} =
        live(conn, pattern_path(version, bundle.route, bundle.pattern, "?task=timings"))

      edit_timing_field(view, 2, "arrival", "")
      edit_timing_field(view, 2, "departure", "")

      # Row 3 now departs at 05:30, so row 4's arrival at 01:00 precedes the last
      # timed departure even though the blank row 2 sits between them.
      edit_timing_field(view, 3, "arrival", "05:00")
      edit_timing_field(view, 3, "departure", "05:30")
      edit_timing_field(view, 4, "arrival", "01:00")
      render_click(view, "save_timing")

      assert has_element?(view, "#timing-arrival-4[aria-invalid='true']")
      assert timing_offsets(bundle) == [{0, 0}, {240, 300}, {600, 660}, {900, 900}]
    end
  end

  setup do
    organization =
      organization_fixture(%{alias: "timing-save-blanks-#{System.unique_integer([:positive])}"})

    version = gtfs_version_fixture(organization.id)
    actor = editor_fixture(organization)

    %{
      organization: organization,
      version: version,
      audit: %AuditContext{
        organization_id: organization.id,
        gtfs_version_id: version.id,
        station_stop_id: nil,
        actor_id: actor.id,
        actor_email: actor.email
      }
    }
  end

  defp editor_scope(context) do
    user =
      user_fixture(%{email: "timing-save-#{System.unique_integer([:positive])}@example.com"})

    {:ok, _} =
      Accounts.create_user_org_membership(%{
        user_id: user.id,
        organization_id: context.organization.id,
        roles: ["pathways_studio_editor"]
      })

    %{context | conn: log_in_user(context.conn, user, organization: context.organization)}
  end

  # Four stops whose first and last rows are timepoints, with a timed interior row
  # in the middle that the save can clear.
  defp four_stop_pattern(context, opts) do
    %{organization: organization, version: version} = context
    route_id = Keyword.fetch!(opts, :suffix)
    linked? = Keyword.get(opts, :linked, true)

    route =
      route_fixture(organization.id, version.id, %{
        route_id: route_id,
        route_short_name: route_id,
        route_long_name: "#{route_id} corridor"
      })

    for index <- 1..4 do
      stop_fixture(organization.id, version.id, %{
        stop_id: "#{route_id}_S#{index}",
        stop_name: "#{route_id} Stop #{index}",
        location_type: 0
      })
    end

    bundle =
      schedule_pattern_fixture(organization.id, version.id, %{
        route_id: route_id,
        stops: [
          {"#{route_id}_S1", 0, 0, 1},
          {"#{route_id}_S2", 240, 300, 0},
          {"#{route_id}_S3", 600, 660, 0},
          {"#{route_id}_S4", 900, 900, 1}
        ]
      })

    Map.merge(bundle, %{route: route, trip: linked_trip(context, route_id, bundle, linked?)})
  end

  # A linked trip gives the save something to rematerialize, so the context cases
  # can see the blank reach `stop_times` as the absence of a time. The editor
  # cases use a pattern with no linked trip, which is the path that saves in one
  # click without a review dialog.
  defp linked_trip(context, route_id, bundle, true) do
    %{organization: organization, version: version} = context

    schedule_trip_fixture(organization.id, version.id, route_id, bundle, %{
      service_id: service_id(route_id, context.audit),
      stop_times: [
        {"#{route_id}_S1", "07:00:00", "07:00:00"},
        {"#{route_id}_S2", "07:04:00", "07:05:00"},
        {"#{route_id}_S3", "07:10:00", "07:11:00"},
        {"#{route_id}_S4", "07:15:00", "07:15:00"}
      ]
    })
    |> Map.fetch!(:trip)
  end

  defp linked_trip(_context, _route_id, _bundle, false), do: nil

  # One calendar per pattern, so the linked trip has a real service to run on.
  defp service_id(route_id, audit) do
    service_id = "#{route_id}_wk_#{System.unique_integer([:positive])}"

    assert {:ok, _payload} =
             Gtfs.create_calendar(
               %{
                 service_id: service_id,
                 name: "Weekday #{route_id}",
                 kind: :weekly,
                 monday: 1,
                 tuesday: 1,
                 wednesday: 1,
                 thursday: 1,
                 friday: 1,
                 saturday: 0,
                 sunday: 0,
                 start_date: ~D[2026-01-05],
                 end_date: ~D[2026-02-27]
               },
               audit
             )

    service_id
  end

  # The rows the editor would post once both cells of the interior row are empty.
  defp blanked(bundle) do
    [
      row(bundle, 0),
      %{row(bundle, 1) | arrival_offset: nil, departure_offset: nil},
      %{row(bundle, 2) | arrival_offset: nil, departure_offset: nil},
      row(bundle, 3)
    ]
  end

  defp row(bundle, index) do
    occurrence = Enum.at(occurrences(bundle), index)
    stored = bundle.timing.rows |> Enum.at(index)

    %{
      route_pattern_stop_id: occurrence.id,
      arrival_offset: stored.arrival_offset,
      departure_offset: stored.departure_offset,
      timepoint: stored.timepoint,
      pickup_type: stored.pickup_type,
      drop_off_type: stored.drop_off_type,
      stop_headsign: stored.stop_headsign
    }
  end

  defp row_tail(bundle), do: Enum.map(1..3, &row(bundle, &1))

  defp occurrences(bundle) do
    Repo.all(
      from(o in RoutePatternStop,
        where: o.route_pattern_id == ^bundle.pattern.id,
        order_by: o.position
      )
    )
  end

  defp timing_offsets(bundle) do
    bundle.timing.id
    |> timing_rows()
    |> Enum.map(&{&1.arrival_offset, &1.departure_offset})
  end

  defp timing_rows(timing_id) do
    TimedPatternStop
    |> join(:inner, [r], o in assoc(r, :route_pattern_stop))
    |> where([r], r.timed_pattern_id == ^timing_id)
    |> order_by([r, o], asc: o.position)
    |> Repo.all()
  end

  defp set_timepoint(timing_id, occurrence_id, value) do
    TimedPatternStop
    |> where([r], r.timed_pattern_id == ^timing_id and r.route_pattern_stop_id == ^occurrence_id)
    |> Repo.update_all(set: [timepoint: value])
  end

  defp timepoint(timing_id, occurrence_id) do
    TimedPatternStop
    |> where([r], r.timed_pattern_id == ^timing_id and r.route_pattern_stop_id == ^occurrence_id)
    |> Repo.one()
    |> Map.fetch!(:timepoint)
  end

  defp stop_times(trip_id) do
    StopTime
    |> where([s], s.trip_id == ^trip_id)
    |> order_by([s], asc: s.stop_sequence)
    |> Repo.all()
  end

  defp pattern_path(version, route, pattern, suffix) do
    "/gtfs/#{version.id}/routes/#{route.route_id}/patterns/#{pattern.route_pattern_id}#{suffix}"
  end

  # Edits one control through the rendered timing form, so the change event carries
  # every row's current values exactly as a browser posts them.
  defp edit_timing_field(view, position, field, value) do
    position = Integer.to_string(position)

    view
    |> form("#timing-edit-form", %{"timing" => %{position => %{field => value}}})
    |> render_change(%{"_target" => ["timing", position, field]})
  end
end
