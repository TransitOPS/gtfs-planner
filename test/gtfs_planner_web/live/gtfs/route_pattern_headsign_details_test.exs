defmodule GtfsPlannerWeb.Gtfs.RoutePatternHeadsignDetailsTest do
  @moduledoc """
  LiveView coverage for the Details headsign wiring (EV-11): the inline update
  box with the real usage counts, the "Save headsign" save-bar state, the
  headsign-only save that skips the impact dialog and writes exactly the
  selected trips, the direction change that still opens the dialog, the
  unchecked box, Undo and its stale fence, the non-stale save after Undo, the
  post-remount cleanup, and the imported fill.
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
        alias: "headsign-details-#{System.system_time(:nanosecond)}"
      })

    user =
      user_fixture(%{email: "headsign-details-#{System.unique_integer([:positive])}@example.com"})

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

  defp details_path(version, route, pattern, query) do
    "/gtfs/#{version.id}/routes/#{route.route_id}/patterns/#{pattern.route_pattern_id}#{query}"
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

  describe "the inline update box" do
    test "editing the headsign stages the followers with the Save headsign bar",
         %{conn: conn, organization: organization, version: version} do
      context = lincoln_pattern(organization, version, "HS-BOX")

      {:ok, view, _html} =
        live(conn, details_path(version, context.route, context.pattern, "?task=details"))

      assert has_element?(view, "#headsign-usage", "Used by 5 trips")
      assert has_element?(view, "#headsign-usage", "2 show a different headsign")
      assert has_element?(view, "#headsign-usage-review", "Review 2 trips")

      edit_headsign(view, "Lincoln City via Depoe Bay")

      assert has_element?(
               view,
               "#headsign-update-box",
               "Also update 3 trips that show Lincoln City"
             )

      assert has_element?(
               view,
               "#headsign-update-box",
               "2 trips with a different headsign stay as they are."
             )

      assert has_element?(view, "#headsign-update-toggle[checked]")
      assert has_element?(view, "#headsign-update-review", "Review trips")
      refute has_element?(view, "#headsign-usage")
      assert has_element?(view, "#pattern-details-submit", "Save headsign")
      assert has_element?(view, "#pattern-save-status", "Saving updates 3 trips")

      # Returning the field to the stored value brings the usage line back.
      edit_headsign(view, "Lincoln City")

      assert has_element?(view, "#headsign-usage", "Used by 5 trips")
      refute has_element?(view, "#headsign-update-box")
      assert has_element?(view, "#pattern-details-submit", "Save details")
    end

    test "unchecking the box saves only the pattern headsign",
         %{conn: conn, organization: organization, version: version} do
      context = lincoln_pattern(organization, version, "HS-UNCHECKED")

      {:ok, view, _html} =
        live(conn, details_path(version, context.route, context.pattern, "?task=details"))

      edit_headsign(view, "Lincoln City via Depoe Bay")
      render_click(element(view, "#headsign-update-toggle"))
      assert has_element?(view, "#headsign-update-toggle:not([checked])")

      assert has_element?(
               view,
               "#pattern-save-status",
               "Saving changes trips you add later, not existing trips"
             )

      render_submit(element(view, "#pattern-details-form"), %{
        "pattern" => edited_params(context.pattern, %{})
      })

      refute has_element?(view, "#details-impact-dialog[data-open='true']")
      assert Repo.get!(RoutePattern, context.pattern.id).headsign == "Lincoln City via Depoe Bay"
      assert trip_headsigns(context.follower_trips) == %{"Lincoln City" => 3}
      assert Repo.reload!(context.typo_trip).trip_headsign == "Lincoln city"
      assert Repo.reload!(context.other_trip).trip_headsign == "Roads End via Lincoln City"
    end
  end

  describe "saving" do
    test "a headsign-only save writes the pattern and the selected trips without the dialog",
         %{conn: conn, organization: organization, version: version} do
      context = lincoln_pattern(organization, version, "HS-SAVE")

      {:ok, view, _html} =
        live(conn, details_path(version, context.route, context.pattern, "?task=details"))

      edit_headsign(view, "Lincoln City via Depoe Bay")

      render_submit(element(view, "#pattern-details-form"), %{
        "pattern" => edited_params(context.pattern, %{})
      })

      refute has_element?(view, "#details-impact-dialog[data-open='true']")
      assert Repo.get!(RoutePattern, context.pattern.id).headsign == "Lincoln City via Depoe Bay"
      assert trip_headsigns(context.follower_trips) == %{"Lincoln City via Depoe Bay" => 3}
      assert Repo.reload!(context.typo_trip).trip_headsign == "Lincoln city"
      assert Repo.reload!(context.other_trip).trip_headsign == "Roads End via Lincoln City"

      assert has_element?(view, "#headsign-result", "Headsign saved · 3 trips updated")
      assert has_element?(view, "#headsign-result", "3 trips now show Lincoln City via Depoe Bay")
      assert has_element?(view, "#headsign-result", "2 trips show a different headsign.")
      assert has_element?(view, "#headsign-undo", "Undo headsign change")
      assert has_element?(view, "#headsign-result-review", "Review 2 trips")
      assert has_element?(view, "#headsign-usage", "2 show a different headsign")
    end

    test "a direction change in the same save still opens the dialog and carries the selection",
         %{conn: conn, organization: organization, version: version} do
      context = lincoln_pattern(organization, version, "HS-DIR")

      {:ok, view, _html} =
        live(conn, details_path(version, context.route, context.pattern, "?task=details"))

      edit_headsign(view, "Lincoln City via Depoe Bay")

      render_submit(element(view, "#pattern-details-form"), %{
        "pattern" => edited_params(context.pattern, %{"direction_id" => "1"})
      })

      assert has_element?(view, "#details-impact-dialog[data-open='true']", "Update 5 trips?")
      assert Repo.get!(RoutePattern, context.pattern.id).direction_id == 0

      render_click(element(view, "#details-impact-dialog-confirm"))

      assert Repo.get!(RoutePattern, context.pattern.id).direction_id == 1
      assert Repo.get!(RoutePattern, context.pattern.id).headsign == "Lincoln City via Depoe Bay"
      assert trip_headsigns(context.follower_trips) == %{"Lincoln City via Depoe Bay" => 3}

      assert Enum.all?(
               context.follower_trips ++ [context.typo_trip, context.other_trip],
               fn trip ->
                 Repo.reload!(trip).direction_id == 1
               end
             )

      assert has_element?(view, "#headsign-result", "3 trips now show Lincoln City via Depoe Bay")
    end
  end

  describe "undo" do
    test "undo restores the pattern headsign and the trips and says so",
         %{conn: conn, organization: organization, version: version} do
      context = lincoln_pattern(organization, version, "HS-UNDO")

      {:ok, view, _html} =
        live(conn, details_path(version, context.route, context.pattern, "?task=details"))

      edit_headsign(view, "Lincoln City via Depoe Bay")

      render_submit(element(view, "#pattern-details-form"), %{
        "pattern" => edited_params(context.pattern, %{})
      })

      render_click(element(view, "#headsign-undo"))

      assert Repo.get!(RoutePattern, context.pattern.id).headsign == "Lincoln City"
      assert trip_headsigns(context.follower_trips) == %{"Lincoln City" => 3}
      assert has_element?(view, "#pattern-save-status", "Headsign change undone")

      assert has_element?(
               view,
               "#pattern-save-status",
               "The pattern’s headsign is Lincoln City again"
             )

      refute has_element?(view, "#headsign-result")
      assert has_element?(view, "#headsign-usage", "Used by 5 trips")

      # AC-17: the reload after Undo refreshes the fingerprint, so the next
      # details save is not reported stale.
      edit_headsign(view, "Lincoln City via Depoe Bay")

      render_submit(element(view, "#pattern-details-form"), %{
        "pattern" => edited_params(context.pattern, %{})
      })

      refute has_element?(view, "#details-stale")
      refute has_element?(view, "#details-impact-dialog[data-open='true']")
      assert Repo.get!(RoutePattern, context.pattern.id).headsign == "Lincoln City via Depoe Bay"
    end

    test "undo after a trip changed elsewhere writes nothing and says the trips changed",
         %{conn: conn, organization: organization, version: version} do
      context = lincoln_pattern(organization, version, "HS-STALE")

      {:ok, view, _html} =
        live(conn, details_path(version, context.route, context.pattern, "?task=details"))

      edit_headsign(view, "Lincoln City via Depoe Bay")

      render_submit(element(view, "#pattern-details-form"), %{
        "pattern" => edited_params(context.pattern, %{})
      })

      # A second session changes one of the selected trips outside this page.
      edited = hd(context.follower_trips)

      Repo.update_all(
        from(t in Trip, where: t.id == ^edited.id),
        set: [trip_headsign: "Changed elsewhere"]
      )

      render_click(element(view, "#headsign-undo"))

      assert has_element?(view, "#error", "The trips changed since the headsign was saved")
      assert has_element?(view, "#error", "Check History")
      assert Repo.get!(RoutePattern, context.pattern.id).headsign == "Lincoln City via Depoe Bay"
      assert Repo.reload!(edited).trip_headsign == "Changed elsewhere"

      assert Repo.reload!(Enum.at(context.follower_trips, 1)).trip_headsign ==
               "Lincoln City via Depoe Bay"

      refute has_element?(view, "#headsign-undo")
    end

    test "a remount offers no undo", %{conn: conn, organization: organization, version: version} do
      context = lincoln_pattern(organization, version, "HS-REMOUNT")

      {:ok, view, _html} =
        live(conn, details_path(version, context.route, context.pattern, "?task=details"))

      edit_headsign(view, "Lincoln City via Depoe Bay")

      render_submit(element(view, "#pattern-details-form"), %{
        "pattern" => edited_params(context.pattern, %{})
      })

      assert has_element?(view, "#headsign-undo")

      {:ok, remounted, _html} =
        live(conn, details_path(version, context.route, context.pattern, "?task=details"))

      refute has_element?(remounted, "#headsign-result")
      refute has_element?(remounted, "#headsign-undo")
    end
  end

  describe "the imported fill" do
    test "Use {value} for this pattern fills the field without saving",
         %{conn: conn, organization: organization, version: version} do
      route = route_fixture(organization.id, version.id, %{route_id: "HS_IMPORT"})

      pattern =
        route_pattern_fixture(organization.id, version.id, %{
          route_id: route.route_id,
          route_pattern_id: "HS-IMPORT",
          route_pattern_name: "Imported",
          headsign: nil,
          direction_id: 0
        })

      stops = Enum.map(1..2, &stop(organization, version, "HS_IMPORT", &1))

      occurrences =
        stops
        |> Enum.with_index(1)
        |> Enum.map(fn {stop, position} ->
          route_pattern_stop_fixture(pattern, stop.stop_id, position)
        end)

      timing = timed_pattern_fixture(pattern, %{name: "Weekday base", headsign: "Lincoln City"})

      Enum.each(occurrences, fn occurrence ->
        timed_pattern_stop_fixture(timing, occurrence, %{arrival_offset: 0, departure_offset: 0})
      end)

      carried_trip =
        trip_fixture(organization.id, version.id, route.route_id, %{
          trip_id: "HS_IMPORT_T1",
          trip_headsign: "Lincoln City"
        })

      trip_pattern_metadata_fixture(carried_trip, %{
        route_pattern_id: pattern.route_pattern_id,
        timed_pattern_id: timing.id,
        pattern_derivation_state: "linked"
      })

      {:ok, view, _html} = live(conn, details_path(version, route, pattern, "?task=details"))

      assert has_element?(view, "#headsign-usage", "Timings set the headsign here")
      assert has_element?(view, "#headsign-usage-lift", "Use Lincoln City for this pattern")

      render_click(element(view, "#headsign-usage-lift"))

      assert has_element?(view, "#pattern-details-headsign[value='Lincoln City']")
      assert Repo.get!(RoutePattern, pattern.id).headsign == nil
      refute has_element?(view, "#details-impact-dialog[data-open='true']")

      # The staged box waits for the save; no trip was written.
      assert has_element?(view, "#headsign-update-box")
      assert Repo.reload!(carried_trip).trip_headsign == "Lincoln City"
    end

    test "a first headsign for blank trips offers the give-branch box and writes them on save",
         %{conn: conn, organization: organization, version: version} do
      route = route_fixture(organization.id, version.id, %{route_id: "HS_FIRST"})

      pattern =
        route_pattern_fixture(organization.id, version.id, %{
          route_id: route.route_id,
          route_pattern_id: "HS-FIRST",
          route_pattern_name: "First headsign",
          headsign: nil,
          direction_id: 0
        })

      stops = Enum.map(1..2, &stop(organization, version, "HS_FIRST", &1))

      occurrences =
        stops
        |> Enum.with_index(1)
        |> Enum.map(fn {stop, position} ->
          route_pattern_stop_fixture(pattern, stop.stop_id, position)
        end)

      timing = timed_pattern_fixture(pattern, %{name: "Weekday"})

      Enum.each(occurrences, fn occurrence ->
        timed_pattern_stop_fixture(timing, occurrence, %{arrival_offset: 0, departure_offset: 0})
      end)

      blank_trips =
        Enum.map(1..2, fn n ->
          trip =
            trip_fixture(organization.id, version.id, route.route_id, %{
              trip_id: "HS_FIRST_T#{n}",
              trip_headsign: nil
            })

          trip_pattern_metadata_fixture(trip, %{
            route_pattern_id: pattern.route_pattern_id,
            timed_pattern_id: timing.id,
            pattern_derivation_state: "linked"
          })

          trip
        end)

      differing_trip =
        trip_fixture(organization.id, version.id, route.route_id, %{
          trip_id: "HS_FIRST_T3",
          trip_headsign: "Downtown"
        })

      trip_pattern_metadata_fixture(differing_trip, %{
        route_pattern_id: pattern.route_pattern_id,
        timed_pattern_id: timing.id,
        pattern_derivation_state: "linked"
      })

      {:ok, view, _html} = live(conn, details_path(version, route, pattern, "?task=details"))

      assert has_element?(view, "#headsign-usage", "Used by 3 trips")

      edit_headsign(view, "Lincoln City")

      assert has_element?(
               view,
               "#headsign-update-box",
               "Also give 2 trips with no headsign this headsign"
             )

      assert has_element?(view, "#headsign-update-toggle[checked]")

      render_submit(element(view, "#pattern-details-form"), %{
        "pattern" => %{
          "name" => "First headsign",
          "direction_id" => "0",
          "headsign" => "Lincoln City",
          "time_desc" => "",
          "typicality" => "0",
          "sort_order" => ""
        }
      })

      refute has_element?(view, "#details-impact-dialog[data-open='true']")
      assert Repo.get!(RoutePattern, pattern.id).headsign == "Lincoln City"
      assert Enum.all?(blank_trips, &(Repo.reload!(&1).trip_headsign == "Lincoln City"))
      assert Repo.reload!(differing_trip).trip_headsign == "Downtown"
    end
  end
end
