defmodule GtfsPlannerWeb.Gtfs.RoutePatternHeadsignReviewTest do
  @moduledoc """
  LiveView coverage for the Details review drawer wiring (EV-12): the
  change-mode selection round trip into the saved set, a trip added in the
  review, the exceptions-mode reset of the likely typo with its done message
  and Undo, the stale reset after a concurrent edit with Refresh list keeping
  the still-differing selection, the non-stale Details save after a reset, and
  the drawer's close-and-return-focus contract.
  """

  use GtfsPlannerWeb.ConnCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures
  import GtfsPlanner.GtfsFixtures

  alias GtfsPlanner.Gtfs.RoutePattern
  alias GtfsPlanner.Gtfs.Trip
  alias GtfsPlanner.Repo

  setup %{conn: conn} do
    organization =
      organization_fixture(%{
        alias: "headsign-review-#{System.system_time(:nanosecond)}"
      })

    user =
      user_fixture(%{email: "headsign-review-#{System.unique_integer([:positive])}@example.com"})

    {:ok, _membership} =
      GtfsPlanner.Accounts.create_user_org_membership(%{
        user_id: user.id,
        organization_id: organization.id,
        roles: ["pathways_studio_editor"]
      })

    version = gtfs_version_fixture(organization.id)
    conn = log_in_user(conn, user, organization: organization)

    %{conn: conn, user: user, organization: organization, version: version}
  end

  # The card's staged shape: pattern headsign "Lincoln City" over five linked
  # trips — three followers, one likely typo, one differing value.
  defp lincoln_pattern(organization, version, pattern_id) do
    route =
      route_fixture(organization.id, version.id, %{
        route_id: "HS_#{pattern_id}",
        route_short_name: "HS",
        route_long_name: "Headsign corridor"
      })

    stops = Enum.map(1..2, &stop(organization, version, "HS_#{pattern_id}", &1))

    pattern =
      route_pattern_fixture(organization.id, version.id, %{
        route_id: route.route_id,
        route_pattern_id: pattern_id,
        route_pattern_name: "Lincoln runs",
        headsign: "Lincoln City",
        direction_id: 0
      })

    occurrences =
      stops
      |> Enum.with_index(1)
      |> Enum.map(fn {stop, position} ->
        route_pattern_stop_fixture(pattern, stop.stop_id, position)
      end)

    timing = timed_pattern_fixture(pattern, %{name: "Weekday"})

    Enum.each(occurrences, fn occurrence ->
      timed_pattern_stop_fixture(timing, occurrence, %{
        arrival_offset: 0,
        departure_offset: 0
      })
    end)

    trips =
      [
        {"T1", "Lincoln City"},
        {"T2", "Lincoln City"},
        {"T3", "Lincoln City"},
        {"T4", "Lincoln city"},
        {"T5", "Roads End via Lincoln City"}
      ]
      |> Enum.map(fn {suffix, headsign} ->
        trip =
          trip_fixture(organization.id, version.id, route.route_id, %{
            trip_id: "#{pattern_id}_#{suffix}",
            trip_headsign: headsign,
            direction_id: 0
          })

        trip_pattern_metadata_fixture(trip, %{
          route_pattern_id: pattern.route_pattern_id,
          timed_pattern_id: timing.id,
          pattern_derivation_state: "linked",
          direction_id: 0
        })

        trip
      end)

    %{
      route: route,
      pattern: pattern,
      timing: timing,
      follower_trips: Enum.take(trips, 3),
      typo_trip: Enum.at(trips, 3),
      other_trip: Enum.at(trips, 4)
    }
  end

  defp stop(organization, version, route_id, index) do
    stop_fixture(organization.id, version.id, %{
      stop_id: "#{route_id}_S#{index}",
      stop_name: "Stop #{index}",
      location_type: 0
    })
  end

  defp details_path(version, route, pattern) do
    "/gtfs/#{version.id}/routes/#{route.route_id}/patterns/#{pattern.route_pattern_id}?task=details"
  end

  defp trip_headsigns(trips) do
    trips
    |> Enum.map(&Repo.reload!(&1).trip_headsign)
    |> Enum.frequencies()
  end

  defp edited_params(pattern, overrides) do
    Map.merge(
      %{
        "name" => pattern.route_pattern_name,
        "direction_id" => to_string(pattern.direction_id),
        "headsign" => "Lincoln City via Depoe Bay",
        "time_desc" => pattern.route_pattern_time_desc || "",
        "typicality" => to_string(pattern.route_pattern_typicality || 0),
        "sort_order" => ""
      },
      overrides
    )
  end

  defp edit_headsign(view, value) do
    render_change(view, "validate_details", %{"pattern" => %{"headsign" => value}})
  end

  defp checked?(view, trips) do
    Enum.all?(trips, fn trip ->
      has_element?(view, "input[phx-value-trip='#{trip.id}'][checked]")
    end)
  end

  defp unchecked?(view, trips) do
    Enum.all?(trips, fn trip ->
      has_element?(view, "input[phx-value-trip='#{trip.id}']:not([checked])")
    end)
  end

  describe "the change-mode drawer" do
    test "the selection round trip stages exactly the checked trips",
         %{conn: conn, organization: organization, version: version} do
      context = lincoln_pattern(organization, version, "HS-CHG")

      {:ok, view, _html} = live(conn, details_path(version, context.route, context.pattern))

      edit_headsign(view, "Lincoln City via Depoe Bay")
      render_click(element(view, "#headsign-update-review"))

      assert has_element?(view, "#headsign-review-drawer", "Trips the new headsign reaches")
      assert has_element?(view, "#headsign-review-drawer", "Preview · not saved")
      assert has_element?(view, "#headsign-review-drawer", "Lincoln City via Depoe Bay")
      assert has_element?(view, "#headsign-review-drawer", "These trips match the old headsign")
      assert has_element?(view, "#headsign-review-drawer-group-0-toggle[checked]")
      assert checked?(view, context.follower_trips)
      assert unchecked?(view, [context.typo_trip, context.other_trip])

      render_click(view, "select_headsign_trip", %{"trip" => hd(context.follower_trips).id})
      assert checked?(view, Enum.drop(context.follower_trips, 1))
      assert has_element?(view, "#headsign-review-drawer-group-0-toggle[data-indeterminate]")

      render_click(element(view, "#headsign-review-drawer-use"))

      refute has_element?(view, "#headsign-review-drawer")

      assert has_element?(
               view,
               "#headsign-update-box",
               "Also update 2 of 3 trips that show Lincoln City"
             )

      assert has_element?(view, "#headsign-update-toggle[checked]")
      assert has_element?(view, "#pattern-save-status", "Saving updates 2 trips")

      render_submit(element(view, "#pattern-details-form"), %{
        "pattern" => edited_params(context.pattern, %{})
      })

      refute has_element?(view, "#details-impact-dialog[data-open='true']")
      assert Repo.get!(RoutePattern, context.pattern.id).headsign == "Lincoln City via Depoe Bay"

      assert trip_headsigns(Enum.drop(context.follower_trips, 1)) ==
               %{"Lincoln City via Depoe Bay" => 2}

      assert Repo.reload!(hd(context.follower_trips)).trip_headsign == "Lincoln City"
      assert Repo.reload!(context.typo_trip).trip_headsign == "Lincoln city"
    end

    test "a trip added in the review is written with the followers",
         %{conn: conn, organization: organization, version: version} do
      context = lincoln_pattern(organization, version, "HS-EXTRA")

      {:ok, view, _html} = live(conn, details_path(version, context.route, context.pattern))

      edit_headsign(view, "Lincoln City via Depoe Bay")
      render_click(element(view, "#headsign-update-review"))

      render_click(view, "select_headsign_trip", %{"trip" => context.typo_trip.id})

      assert has_element?(view, "#headsign-review-drawer-status", "4 trips selected")

      render_click(element(view, "#headsign-review-drawer-use"))

      assert has_element?(
               view,
               "#headsign-update-box",
               "Also update 3 trips that show Lincoln City"
             )

      assert has_element?(view, "#headsign-update-box", "Plus 1 trip you added in the review.")

      render_submit(element(view, "#pattern-details-form"), %{
        "pattern" => edited_params(context.pattern, %{})
      })

      refute has_element?(view, "#details-impact-dialog[data-open='true']")
      assert Repo.get!(RoutePattern, context.pattern.id).headsign == "Lincoln City via Depoe Bay"
      assert trip_headsigns(context.follower_trips) == %{"Lincoln City via Depoe Bay" => 3}
      assert Repo.reload!(context.typo_trip).trip_headsign == "Lincoln City via Depoe Bay"
      assert Repo.reload!(context.other_trip).trip_headsign == "Roads End via Lincoln City"
    end
  end

  describe "the exceptions drawer" do
    test "selecting the likely typo and applying writes it, with done and Undo",
         %{conn: conn, organization: organization, version: version} do
      context = lincoln_pattern(organization, version, "HS-EXC")

      {:ok, view, _html} = live(conn, details_path(version, context.route, context.pattern))

      html = render_click(element(view, "#headsign-usage-review"))
      assert html =~ "Loading trips…"

      render_async(view)

      assert has_element?(view, "#headsign-review-drawer", "Trips with a different headsign")
      assert has_element?(view, "#headsign-review-drawer", "3 of 5 trips show")
      assert has_element?(view, "#headsign-review-drawer", "Lincoln city")
      assert has_element?(view, "#headsign-review-drawer", "Likely typo")

      assert has_element?(view, "#headsign-review-drawer", "Roads End via Lincoln City")
      refute has_element?(view, "#headsign-review-drawer-group-0-toggle[checked]")

      assert has_element?(view, "#headsign-review-drawer-apply", "Change trips")
      assert has_element?(view, "#headsign-review-drawer-apply[disabled]")

      render_click(view, "select_headsign_typos")

      assert has_element?(view, "#headsign-review-drawer-apply", "Change 1 trip to Lincoln City")
      assert checked?(view, [context.typo_trip])

      render_click(element(view, "#headsign-review-drawer-apply"))

      assert has_element?(view, "#headsign-review-drawer-done", "1 trip now shows Lincoln City")
      assert has_element?(view, "#headsign-review-drawer-done", "kept a different headsign")
      assert has_element?(view, "#headsign-review-drawer-undo", "Undo")
      assert Repo.reload!(context.typo_trip).trip_headsign == "Lincoln City"

      # CR-6: the write reloaded the page, so the counts behind the drawer are
      # already current.
      assert has_element?(view, "#headsign-usage", "1 shows a different headsign")

      render_click(element(view, "#headsign-review-drawer-undo"))

      refute has_element?(view, "#headsign-review-drawer")
      assert Repo.reload!(context.typo_trip).trip_headsign == "Lincoln city"

      assert has_element?(view, "#pattern-save-status", "Headsign change undone")
      assert has_element?(view, "#headsign-usage", "2 show a different headsign")
    end

    test "a stale reset writes nothing and Refresh list keeps the still-differing selection",
         %{conn: conn, organization: organization, version: version} do
      context = lincoln_pattern(organization, version, "HS-STALE")

      {:ok, view, _html} = live(conn, details_path(version, context.route, context.pattern))

      render_click(element(view, "#headsign-usage-review"))
      render_async(view)
      render_click(view, "select_headsign_typos")

      # A second session changes the selected trip outside this page.
      Repo.update_all(
        from(t in Trip, where: t.id == ^context.typo_trip.id),
        set: [trip_headsign: "Changed elsewhere"]
      )

      render_click(element(view, "#headsign-review-drawer-apply"))

      assert has_element?(
               view,
               "#headsign-review-drawer-stale",
               "These trips changed since the list loaded"
             )

      assert Repo.reload!(context.typo_trip).trip_headsign == "Changed elsewhere"

      assert Enum.all?(
               context.follower_trips,
               &(Repo.reload!(&1).trip_headsign == "Lincoln City")
             )

      # Refresh list reloads the groups; the trip still differs, so it stays
      # selected, now fenced on its current value.
      render_click(element(view, "#headsign-review-drawer-apply"))
      render_async(view)

      refute has_element?(view, "#headsign-review-drawer-stale")
      assert has_element?(view, "#headsign-review-drawer", "Changed elsewhere")
      assert checked?(view, [context.typo_trip])
      assert has_element?(view, "#headsign-review-drawer-apply", "Change 1 trip to Lincoln City")

      render_click(element(view, "#headsign-review-drawer-apply"))

      assert has_element?(view, "#headsign-review-drawer-done", "1 trip now shows Lincoln City")
      assert Repo.reload!(context.typo_trip).trip_headsign == "Lincoln City"
    end

    test "a Details save after a reset is not stale",
         %{conn: conn, organization: organization, version: version} do
      context = lincoln_pattern(organization, version, "HS-AFTER")

      {:ok, view, _html} = live(conn, details_path(version, context.route, context.pattern))

      render_click(element(view, "#headsign-usage-review"))
      render_async(view)
      render_click(view, "select_headsign_typos")
      render_click(element(view, "#headsign-review-drawer-apply"))

      assert has_element?(view, "#headsign-review-drawer-done")
      assert Repo.reload!(context.typo_trip).trip_headsign == "Lincoln City"

      render_click(element(view, "#headsign-review-drawer-cancel"))
      refute has_element?(view, "#headsign-review-drawer")

      edit_headsign(view, "Lincoln City via Depoe Bay")

      render_submit(element(view, "#pattern-details-form"), %{
        "pattern" => edited_params(context.pattern, %{})
      })

      refute has_element?(view, "#details-stale")
      refute has_element?(view, "#details-impact-dialog[data-open='true']")
      assert Repo.get!(RoutePattern, context.pattern.id).headsign == "Lincoln City via Depoe Bay"
      assert trip_headsigns(context.follower_trips) == %{"Lincoln City via Depoe Bay" => 3}
    end

    test "closing the drawer hands focus back to its opener",
         %{conn: conn, organization: organization, version: version} do
      context = lincoln_pattern(organization, version, "HS-FOCUS")

      {:ok, view, _html} = live(conn, details_path(version, context.route, context.pattern))

      # The change-mode drawer returns focus to the update box's review button.
      edit_headsign(view, "Lincoln City via Depoe Bay")
      render_click(element(view, "#headsign-update-review"))

      assert has_element?(
               view,
               "#headsign-review-drawer-overlay[data-return-focus-id='headsign-update-review']"
             )

      render_click(element(view, "#headsign-review-drawer-cancel"))
      refute has_element?(view, "#headsign-review-drawer")

      # The exceptions drawer returns focus to the usage line's review button;
      # the field goes back to the stored value so the usage line returns.
      edit_headsign(view, "Lincoln City")
      assert has_element?(view, "#headsign-usage-review")

      render_click(element(view, "#headsign-usage-review"))
      render_async(view)

      assert has_element?(
               view,
               "#headsign-review-drawer-overlay[data-return-focus-id='headsign-usage-review']"
             )

      # The event the Escape key and the header close button both dispatch.
      render_click(view, "close_drawer", %{})
      refute has_element?(view, "#headsign-review-drawer")
      assert has_element?(view, "#headsign-usage-review")
    end
  end
end
