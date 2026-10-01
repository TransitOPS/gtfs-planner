defmodule GtfsPlannerWeb.Gtfs.RoutePatternGroupingLiveTest do
  @moduledoc """
  The grouping review at `patterns?review=group`: one card per groupable stop
  order, the direction the preview suggested, the states a refused apply renders,
  and what each of them writes.

  The fixture is the North Coast Transit supplement the trip-grouping prototype
  and `GtfsPlanner.Gtfs.RoutePatterns.GroupingPreviewTest` both describe: one
  saved pattern over 13 stops, 18 direction-less trips over that same order and 6
  over its first six stops. Every expected value here is a literal from that
  scenario, the GTFS reference and the spec's rules; nothing computes one.
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
  alias GtfsPlanner.Gtfs.Trip
  alias GtfsPlanner.Repo

  @full_trips 18
  @short_trips 6
  @stop_count 13
  @short_stop_count 6

  setup %{conn: conn} do
    organization =
      organization_fixture(%{alias: "grouping-#{System.unique_integer([:positive])}"})

    user =
      user_fixture(%{email: "grouping-#{System.unique_integer([:positive])}@example.com"})

    {:ok, _membership} =
      Accounts.create_user_org_membership(%{
        user_id: user.id,
        organization_id: organization.id,
        roles: ["pathways_studio_editor"]
      })

    version = gtfs_version_fixture(organization.id)
    conn = log_in_user(conn, user, organization: organization)

    %{conn: conn, user: user, organization: organization, version: version}
  end

  describe "opening the review" do
    test "shows one card per groupable stop order with the suggested direction preselected",
         %{conn: conn, organization: organization, version: version} do
      build_scenario(organization, version, "GRP1")

      {:ok, view, _html} = live(conn, review_path(version, "GRP1"))

      assert has_element?(view, "#grouping-review")
      assert length(cards(view)) == 2

      full = group_key(organization, version, "GRP1", stops_count(@stop_count))
      short = group_key(organization, version, "GRP1", stops_count(@short_stop_count))
      # The 18-trip group serves exactly the saved pattern's stops in order, so
      # rule 4 suggests the pattern's own Direction 0.
      assert has_element?(
               view,
               "##{card_id(full)} [name='#{direction_name(full)}'][value='0'][checked]"
             )

      # The short order is answered by rule 4's `within` arm, not asked: it runs
      # inside the saved pattern's order.
      assert text(view, "##{card_id(short)}") =~ "Direction"
      refute text(view, "##{card_id(short)}") =~ "Which way is Direction 0?"
      assert has_element?(view, "##{direction_id(short, 0)}-suggested")

      assert has_element?(
               view,
               "##{reason_id(short)}",
               "runs within one of this route’s patterns"
             )

      refute has_element?(view, "##{direction_id(full, 1)}-suggested")
      # The reason names the rule that produced the suggestion.
      assert has_element?(
               view,
               "##{reason_id(full)}",
               "starts and ends at the same stops, in the same order"
             )

      # The card names what the trips are and what they will join.
      assert text(view, "##{card_id(full)}") =~ "18 trips"
      assert text(view, "##{card_id(full)}") =~ "13 stops"
      assert text(view, "##{card_id(full)}") =~ "Joins pattern_full"
      assert text(view, "##{card_id(full)}") =~ "Line Stop 0 → Line Stop 12"
    end

    test "a card no pattern can answer asks which way Direction 0 is",
         %{conn: conn, organization: organization, version: version} do
      # No saved pattern at all, so neither rule 4 answer applies to any group.
      build_paired_scenario(organization, version, "GRP2")

      {:ok, view, _html} = live(conn, review_path(version, "GRP2"))

      outbound = group_key(organization, version, "GRP2", starts_at("Line Stop 0"))
      inbound = group_key(organization, version, "GRP2", starts_at("Line Stop 5"))
      # The two orders are each other's reverse, so neither a pattern nor the
      # route can say which is Direction 0 and the card asks the question outright.
      assert text(view, "##{card_id(outbound)}") =~ "Which way is Direction 0?"
      assert text(view, "##{reason_id(outbound)}") =~ "runs these same stops the other way"
      assert text(view, "##{card_id(inbound)}") =~ "Which way is Direction 0?"
      # A paired card has no suggestion, so neither radio is preselected and no
      # card in this route carries a Suggested badge.
      for key <- [outbound, inbound], direction <- [0, 1] do
        refute has_element?(view, "##{direction_id(key, direction)}[checked]")
        refute has_element?(view, "##{direction_id(key, direction)}-suggested")
      end
    end

    test "shows the trips it is not offering and why", %{
      conn: conn,
      organization: organization,
      version: version
    } do
      build_scenario(organization, version, "GRP3")

      {:ok, view, _html} = live(conn, review_path(version, "GRP3"))
      # The 3 blocked trips are named in the operator's own words, so the review
      # reads as smaller on purpose rather than silently.
      blocked = text(view, "#grouping-blocked")

      assert blocked =~ "Not offered here: 3 trips with other problems"
      assert blocked =~ "2 with times out of order"
      assert blocked =~ "1 that serves a station"
    end

    test "writes nothing", %{conn: conn, organization: organization, version: version} do
      scenario = build_scenario(organization, version, "GRP4")
      before = linkage(organization)

      {:ok, _view, _html} = live(conn, review_path(version, "GRP4"))

      assert linkage(organization) == before

      assert Repo.aggregate(from(t in Trip, where: t.route_id == "GRP4"), :count) ==
               scenario.trip_count
    end
  end

  describe "the target chooser" do
    test "appears only for a card with more than one candidate", %{
      conn: conn,
      organization: organization,
      version: version
    } do
      build_scenario(organization, version, "GRP5")

      {:ok, view, _html} = live(conn, review_path(version, "GRP5"))

      full = group_key(organization, version, "GRP5", stops_count(@stop_count))

      refute has_element?(view, "##{target_id(full)}")
    end

    test "offers the new pattern and each candidate when a card has two", %{
      conn: conn,
      organization: organization,
      version: version
    } do
      build_scenario(organization, version, "GRP6", two_candidates: true)

      {:ok, view, _html} = live(conn, review_path(version, "GRP6"))

      full = group_key(organization, version, "GRP6", stops_count(@stop_count))

      assert has_element?(view, "##{target_id(full)}")

      chooser =
        view
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("##{target_id(full)}")
        |> LazyHTML.text()

      assert chooser =~ "Creates a new pattern in this direction"
      assert chooser =~ "Joins pattern_full"
      assert chooser =~ "Joins pattern_twin"
    end
  end

  describe "applying the review" do
    test "groups the trips, patches to the list and says what it did",
         %{conn: conn, organization: organization, version: version} do
      build_scenario(organization, version, "GRP7")

      {:ok, view, _html} = live(conn, review_path(version, "GRP7"))

      full = group_key(organization, version, "GRP7", stops_count(@stop_count))
      short = group_key(organization, version, "GRP7", stops_count(@short_stop_count))

      render_change(view |> element("#grouping-form"), %{"grouping" => selections(full, short)})

      assert render_submit(view |> element("#grouping-form")) =~ "Grouped"

      assert_patch(view, "/gtfs/#{version.id}/routes/GRP7/patterns")

      html = render(view)

      assert html =~ ~s(id="patterns-grouped")
      assert html =~ "Grouped #{@full_trips + @short_trips} trips into patterns"
      assert html =~ "their times did not change"
      # Both groups got their chosen direction, written on the trips themselves.
      assert directions(organization, "full") == %{0 => @full_trips}
      assert directions(organization, "short") == %{0 => @short_trips}

      assert Repo.aggregate(from(t in Trip, where: t.route_id == "GRP7"), :count) ==
               @full_trips + @short_trips + 3
    end

    test "an operator's override is what is written, not the suggestion",
         %{conn: conn, organization: organization, version: version} do
      build_scenario(organization, version, "GRP8")

      {:ok, view, _html} = live(conn, review_path(version, "GRP8"))

      full = group_key(organization, version, "GRP8", stops_count(@stop_count))
      short = group_key(organization, version, "GRP8", stops_count(@short_stop_count))

      render_change(view |> element("#grouping-form"), %{
        "grouping" => selections(full, short, direction: "1", short_direction: "0")
      })

      render_submit(view |> element("#grouping-form"))

      assert directions(organization, "full") == %{1 => @full_trips}
      assert directions(organization, "short") == %{0 => @short_trips}
    end

    test "a card with no direction blocks the apply, names it and writes nothing", %{
      conn: conn,
      organization: organization,
      version: version
    } do
      # No pattern, so neither card has a suggestion and neither is preselected:
      # the review opens with both questions unanswered.
      build_paired_scenario(organization, version, "GRP9")
      before = linkage(organization)

      {:ok, view, _html} = live(conn, review_path(version, "GRP9"))

      outbound = group_key(organization, version, "GRP9", starts_at("Line Stop 0"))
      inbound = group_key(organization, version, "GRP9", starts_at("Line Stop 5"))

      html = render_submit(view |> element("#grouping-form"))

      assert html =~ ~s(id="grouping-missing")
      # The card named is the first unanswered one in the preview's own order,
      # which is key order, so the assertion accepts either of the two.
      assert [outbound, inbound] |> Enum.any?(&(html =~ ~s(id="#{missing_id(&1)}")))

      assert html =~ "Choose Direction 0 or Direction 1 for this group"
      assert html =~ ~s(aria-invalid="true")
      # The refusal happened before any write: the trips are exactly as imported,
      # and the review is still open with both cards.
      assert linkage(organization) == before
      assert render(view) =~ ~s(id="grouping-review")
      # Answering both cards and applying is what the operator does next.
      render_change(view |> element("#grouping-form"), %{
        "grouping" => %{
          outbound => %{"direction_id" => "0"},
          inbound => %{"direction_id" => "1"}
        }
      })

      render_submit(view |> element("#grouping-form"))

      assert directions(organization, "outbound") == %{0 => @short_trips}
      assert directions(organization, "inbound") == %{1 => @short_trips}

      _ = inbound
    end

    test "a trip's linkage changed after the review opened returns stale and writes nothing", %{
      conn: conn,
      organization: organization,
      version: version
    } do
      build_scenario(organization, version, "GRP10")

      {:ok, view, _html} = live(conn, review_path(version, "GRP10"))

      full = group_key(organization, version, "GRP10", stops_count(@stop_count))
      short = group_key(organization, version, "GRP10", stops_count(@short_stop_count))
      # A linkage change elsewhere: this trip's row is touched, which rule 7's
      # fingerprint covers.
      moved =
        Repo.one!(
          from(t in Trip,
            where: t.organization_id == ^organization.id and t.trip_id == "supplement_full_1"
          )
        )

      Repo.update_all(from(t in Trip, where: t.id == ^moved.id),
        set: [updated_at: DateTime.add(moved.updated_at, 1, :microsecond)]
      )

      render_change(view |> element("#grouping-form"), %{"grouping" => selections(full, short)})
      html = render_submit(view |> element("#grouping-form"))

      assert html =~ ~s(id="grouping-stale")
      assert html =~ "changed since you opened this review"
      # Rule 7 makes the whole review stale, so nothing at all was written.
      assert grouped_trip_ids(organization) == []
      assert directions(organization, "full") == %{nil => @full_trips}
      assert directions(organization, "short") == %{nil => @short_trips}
    end
  end

  describe "leaving the review" do
    test "keeps the trips as they are and returns to the list", %{
      conn: conn,
      organization: organization,
      version: version
    } do
      build_scenario(organization, version, "GRP11")
      before = linkage(organization)

      {:ok, view, _html} = live(conn, review_path(version, "GRP11"))

      render_click(view, "grouping_cancel")

      assert_patch(view, "/gtfs/#{version.id}/routes/GRP11/patterns")
      assert linkage(organization) == before
    end

    test "an editor whose role was removed reads the review but is offered no action", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      build_scenario(organization, version, "GRP12")

      {:ok, view, _html} = live(conn, review_path(version, "GRP12"))

      membership = Accounts.get_user_org_membership(user.id, organization.id)
      {:ok, _membership} = Accounts.update_user_org_membership(membership, %{roles: []})

      render_click(view, "reload_patterns")

      html = render(view)

      assert html =~ ~s(id="grouping-review")
      assert html =~ "These trips have no direction"
      assert html =~ ~s(id="grouping-submit")
      assert html =~ "disabled"
    end
  end

  # --- helpers ---------------------------------------------------------------
  defp review_path(version, route_id),
    do: "/gtfs/#{version.id}/routes/#{route_id}/patterns?review=group"

  defp card_id(key), do: "grouping-card-#{segment(key)}"

  defp direction_id(key, direction),
    do: "grouping-direction-#{segment(key)}-#{direction}"

  defp reason_id(key), do: "grouping-reason-#{segment(key)}"

  defp target_id(key), do: "grouping-target-#{segment(key)}"

  defp missing_id(key), do: "grouping-missing-#{segment(key)}"

  defp segment(key), do: key |> String.split(":") |> List.last()

  defp direction_name(key), do: "grouping[#{key}][direction_id]"

  defp cards(view) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("article[id^='grouping-card-']")
    |> Enum.to_list()
  end

  defp text(view, selector) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(selector)
    |> LazyHTML.text()
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp selections(full, short, opts \\ []) do
    %{
      full => %{"direction_id" => Keyword.get(opts, :direction, "0")},
      short => %{"direction_id" => Keyword.get(opts, :short_direction, "0")}
    }
  end

  # Everything a refused, stale or cancelled apply must leave untouched.
  defp linkage(organization) do
    from(t in Trip, where: t.organization_id == ^organization.id)
    |> Repo.all()
    |> Enum.map(&{&1.trip_id, &1.direction_id, &1.route_pattern_id, &1.pattern_derivation_state})
    |> Enum.sort()
  end

  # The trips that left the state the fixture put them in. An apply that must
  # write nothing leaves this empty, so the assertion names any that did.
  defp grouped_trip_ids(organization) do
    Repo.all(
      from(t in Trip,
        where:
          t.organization_id == ^organization.id and
            t.pattern_derivation_state != "custom" and not is_nil(t.direction_id),
        select: t.trip_id
      )
    )
    |> Enum.sort()
  end

  # The direction each of a group's trips ended up with, and how many carry it.
  # The linkage itself is compared separately by `linkage/1`.
  defp directions(organization, label) do
    organization
    |> group_trips(label)
    |> Enum.frequencies()
  end

  defp group_trips(organization, label) do
    prefix = "supplement_#{label}_%"

    Repo.all(
      from(t in Trip,
        where: t.organization_id == ^organization.id and like(t.trip_id, ^prefix),
        select: t.direction_id
      )
    )
  end

  # The key the preview assigned to one group, read through the production
  # preview so the test asserts on the same identity the LiveView was handed. A
  # group is named by the stops it serves, so a test can ask for "the 13-stop
  # order" or "the one starting at Line Stop 0" without knowing the hash.
  defp group_key(organization, version, route_id, matcher) do
    {:ok, preview} = Gtfs.preview_left_out(route_id, audit(organization, version))

    Enum.find_value(preview.groups, fn group ->
      if matcher.(group), do: group.key
    end)
  end

  defp stops_count(count), do: &(length(&1.stop_names) == count)
  defp starts_at(name), do: &(List.first(&1.stop_names) == name)

  defp audit(organization, version) do
    %GtfsPlanner.Gtfs.AuditContext{
      organization_id: organization.id,
      gtfs_version_id: version.id,
      station_stop_id: nil,
      actor_id: Ecto.UUID.generate(),
      actor_email: "editor@example.com"
    }
  end

  # --- fixture ---------------------------------------------------------------
  # A route with no pattern at all, carrying one order of six stops and its exact
  # reverse. Rule 4's two pattern answers cannot apply to either, so the pair is
  # what the review asks about.
  defp build_paired_scenario(organization, version, route_id) do
    org_id = organization.id
    version_id = version.id

    route_fixture(org_id, version_id, %{route_id: route_id, route_short_name: route_id})
    scope = insert_stops(org_id, version_id, route_id)
    short = Enum.take(scope.stops, @short_stop_count)

    calendar_attribute_fixture(org_id, version_id, %{
      service_id: "SU1",
      service_description: "Summer weekday supplement"
    })

    insert_group(org_id, version_id, route_id, "outbound", short, @short_trips)
    insert_group(org_id, version_id, route_id, "inbound", Enum.reverse(short), @short_trips)
  end

  # One saved 13-stop pattern in Direction 0, the supplement that matches it
  # (18 trips) and the short turn that does not (6 trips), plus the three trips
  # the preview blocks.
  defp build_scenario(organization, version, route_id, opts \\ []) do
    org_id = organization.id
    version_id = version.id

    route_fixture(org_id, version_id, %{route_id: route_id, route_short_name: route_id})

    scope = insert_stops(org_id, version_id, route_id)
    pattern = insert_pattern(org_id, version_id, route_id, scope)

    if Keyword.get(opts, :two_candidates, false) do
      insert_twin_pattern(org_id, version_id, route_id, scope)
    end

    calendar_attribute_fixture(org_id, version_id, %{
      service_id: "SU1",
      service_description: "Summer weekday supplement"
    })

    insert_group(org_id, version_id, route_id, "full", scope.stops, @full_trips)

    short = Enum.take(scope.stops, @short_stop_count)
    insert_group(org_id, version_id, route_id, "short", short, @short_trips)

    insert_blocked(org_id, version_id, route_id, scope)

    %{pattern: pattern, trip_count: @full_trips + @short_trips + 3}
  end

  # Thirteen boarding stops on one meridian, plus one station. The station is not
  # boarding-eligible, which is what lets the blocked fixture trip be refused.
  defp insert_stops(org_id, version_id, route_id) do
    drawn =
      for index <- 1..@stop_count do
        stop_fixture(org_id, version_id, %{
          stop_id: "#{route_id}_S#{index}",
          stop_name: "Line Stop #{index - 1}",
          location_type: 0,
          stop_lat: 44.0 + index * 0.001,
          stop_lon: -124.0
        }).stop_id
      end

    station =
      stop_fixture(org_id, version_id, %{
        stop_id: "#{route_id}_STATION",
        stop_name: "Depoe Bay Station",
        location_type: 1,
        stop_lat: 44.0,
        stop_lon: -124.0
      })

    %{stops: drawn, station_id: station.stop_id}
  end

  defp insert_pattern(org_id, version_id, route_id, scope) do
    pattern =
      route_pattern_fixture(org_id, version_id, %{
        route_pattern_id: "pattern_full",
        route_id: route_id,
        direction_id: 0,
        route_pattern_name: "Newport Transit Center – Lincoln City",
        derivation_key: "d0-full"
      })

    Enum.each(Enum.with_index(scope.stops, 1), fn {stop_id, position} ->
      route_pattern_stop_fixture(pattern, stop_id, position)
    end)

    pattern
  end

  # A second pattern over the same stops in the same direction is the second
  # candidate the chooser offers; it exists only for the two-candidate case.
  defp insert_twin_pattern(org_id, version_id, route_id, scope) do
    pattern =
      route_pattern_fixture(org_id, version_id, %{
        route_pattern_id: "pattern_twin",
        route_id: route_id,
        direction_id: 0,
        derivation_key: "d0-twin"
      })

    Enum.each(Enum.with_index(scope.stops, 1), fn {stop_id, position} ->
      route_pattern_stop_fixture(pattern, stop_id, position)
    end)

    pattern
  end

  defp insert_group(org_id, version_id, route_id, label, stop_ids, count) do
    band = if label == "full", do: 1, else: 2

    for index <- 1..count do
      trip_id = "supplement_#{label}_#{index}"

      org_id
      |> trip_fixture(version_id, route_id, %{
        trip_id: trip_id,
        service_id: "SU1",
        shape_id: "shape_#{label}"
      })
      |> trip_pattern_metadata_fixture(%{
        direction_id: nil,
        pattern_derivation_state: "custom",
        pattern_derivation_reason: "missing_direction"
      })

      insert_vector(org_id, version_id, trip_id, stop_ids, band)
    end
  end

  # Two trips whose second stop is served first, and one that serves only a
  # station: the two reasons the preview blocks.
  defp insert_blocked(org_id, version_id, route_id, scope) do
    [first, second | _rest] = scope.stops

    for index <- 1..2 do
      trip_id = "out_of_order_#{index}"

      org_id
      |> trip_fixture(version_id, route_id, %{trip_id: trip_id, service_id: "SU1"})
      |> trip_pattern_metadata_fixture(%{
        direction_id: nil,
        pattern_derivation_state: "custom",
        pattern_derivation_reason: "invalid_chronology"
      })

      insert_stop_time(org_id, version_id, trip_id, first, 1, "08:05:00")
      insert_stop_time(org_id, version_id, trip_id, second, 2, "08:00:00")
    end

    trip_id = "station_trip_1"

    org_id
    |> trip_fixture(version_id, route_id, %{trip_id: trip_id, service_id: "SU1"})
    |> trip_pattern_metadata_fixture(%{
      direction_id: nil,
      pattern_derivation_state: "custom",
      pattern_derivation_reason: "unusable_stops"
    })

    insert_stop_time(org_id, version_id, trip_id, scope.station_id, 1, "09:00:00")
  end

  # One minute per stop, and a `stop_sequence` band per group, so the two stop
  # orders are two groups rather than one merged order.
  defp insert_vector(org_id, version_id, trip_id, stop_ids, band) do
    stop_ids
    |> Enum.with_index()
    |> Enum.each(fn {stop_id, index} ->
      minutes = 7 * 60 + index
      time = :io_lib.format("~2..0B:~2..0B:00", [div(minutes, 60), rem(minutes, 60)])

      insert_stop_time(
        org_id,
        version_id,
        trip_id,
        stop_id,
        band * 1000 + index + 1,
        to_string(time)
      )
    end)
  end

  defp insert_stop_time(org_id, version_id, trip_id, stop_id, sequence, time) do
    stop_time_fixture(org_id, version_id, trip_id, stop_id, %{
      stop_sequence: sequence,
      arrival_time: time,
      departure_time: time
    })
  end
end
