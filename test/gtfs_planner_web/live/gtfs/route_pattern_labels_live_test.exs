defmodule GtfsPlannerWeb.Gtfs.RoutePatternLabelsLiveTest do
  @moduledoc """
  The supplied route-pattern labels the Patterns list shows: the grouping, the
  read-only drawer and the one write it offers.

  The fixture is the shape the GTFS reference's `route_patterns.txt` and the MBTA
  `route_patterns` documentation describe, and the numbers the prototype's
  `?state=labels` scenario uses: route pattern `1-0-A` is carried by
  "Newport Transit Center – Lincoln City", a second stop order (`1-0-A-2`) is
  labelled with the same ID, and `1-0-B` carries no label at all. Every expected
  value here is a literal from that scenario; nothing computes one.
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
  alias GtfsPlanner.Gtfs.RoutePattern
  alias GtfsPlanner.Gtfs.Trip
  alias GtfsPlanner.Repo

  @route_id "1"
  @label "1-0-A"
  @child "1-0-A-2"
  @unlabelled "1-0-B"
  @owner_name "Newport Transit Center – Lincoln City"
  @child_name "Newport Transit Center – Gleneden Beach"
  @time_desc "Weekday daytime"
  @child_trips 3
  @owner_stops 13
  @child_stops 11

  setup %{conn: conn} do
    organization =
      organization_fixture(%{alias: "labels-#{System.unique_integer([:positive])}"})

    user =
      user_fixture(%{email: "labels-#{System.unique_integer([:positive])}@example.com"})

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

  describe "the grouped rows" do
    test "group the owner and its child under one exported route pattern ID", context do
      build_scenario(context)
      {:ok, view, _html} = live(context.conn, patterns_path(context))

      assert has_element?(view, "#pattern-label-#{@label}")
      assert text(view, "#pattern-label-#{@label}") =~ "Exported as route pattern #{@label}"
      # The owner and the child are the two stop orders the group exports as one.
      assert text(view, "#pattern-label-#{@label}") =~ "2 stop orders, exported as one"

      # The group is a run of rows: its head, then the owner, then the child. The
      # stream prefixes each row's ID with the stream's own name.
      ids = row_ids(view)

      assert index_of(ids, "patterns-label-#{@label}") < index_of(ids, "patterns-#{@label}")
      assert index_of(ids, "patterns-#{@label}") < index_of(ids, "patterns-#{@child}")
      assert has_element?(view, "tr[data-label='#{@label}'][data-label-role='owner']")
      assert has_element?(view, "tr[data-label='#{@label}'][data-label-role='child']")

      # The rows say what the label does with each name, and the unlabelled
      # pattern is not dragged into a group it is not part of.
      assert text(view, "#pattern-label-note-#{@label}") =~
               "Carries #{@label}; its name is the exported name"

      assert text(view, "#pattern-label-note-#{@child}") =~
               "Under #{@label}; its own name isn’t exported"

      refute has_element?(view, "tr[data-label='#{@unlabelled}']")
      assert has_element?(view, "#pattern-open-#{@unlabelled}")
    end

    test "are read from the same load the list streams, with the label column", context do
      build_scenario(context)

      assert {:ok, %{patterns: patterns}} =
               Gtfs.list_patterns(context.organization.id, context.version.id, @route_id)

      owner = pattern_in(patterns, @label)
      child = pattern_in(patterns, @child)

      assert is_nil(owner.label_pattern_id)
      assert child.label_pattern_id == owner.id
    end
  end

  describe "the label drawer" do
    test "reads the ID, the owner, its typicality and its time description", context do
      build_scenario(context)
      {:ok, view, _html} = live(context.conn, patterns_path(context))

      render_click(view, "open_label", %{"label-id" => @label})

      assert has_element?(view, "#label-drawer")
      # The drawer's own overlay is what opens it; the panel is always rendered
      # while the label is, so the two are checked together.
      assert has_element?(view, "#label-drawer-overlay[data-open='true']")
      assert text(view, "#label-drawer") =~ @label
      assert text(view, "#label-drawer") =~ "Route pattern from the imported feed"

      assert text(view, "#label-drawer-summary") =~
               "Exported as one route pattern for 2 stop orders"

      assert text(view, "#label-owner-name") == @owner_name
      assert text(view, "#label-owner-details") =~ "Route pattern ID"
      assert text(view, "#label-owner-details") =~ "Exported name"
      assert text(view, "#label-owner-details") =~ "Typical"
      assert text(view, "#label-owner-details") =~ @time_desc
      assert text(view, "#label-rename-note") =~ "Renaming it renames the exported route pattern"

      # The child is listed under the label, with the trips that would stop
      # matching it.
      assert text(view, "#label-child-#{@child}") =~ @child_name
      assert text(view, "#label-child-#{@child}") =~ "its own name isn’t exported"
      assert text(view, "#label-child-#{@child}") =~ "3 trips"

      # A label ID is never edited, so the drawer has nothing to type into.
      refute has_element?(view, "#label-drawer input")
      refute has_element?(view, "#label-drawer textarea")
      refute has_element?(view, "#label-drawer form")
    end

    test "sends Edit on the owner to that pattern's Details task", context do
      build_scenario(context)
      {:ok, view, _html} = live(context.conn, patterns_path(context))

      render_click(view, "open_label", %{"label-id" => @label})

      assert text(view, "#label-edit-owner") =~ "Edit on #{@owner_name}"

      assert view
             |> element("#label-edit-owner")
             |> render() =~
               "href=\"/gtfs/#{context.version.id}/routes/#{@route_id}/patterns/#{@label}?task=details\""
    end
  end

  describe "Remove label" do
    test "is offered on the child alone, and takes the grouping away with it", context do
      build_scenario(context)
      {:ok, view, _html} = live(context.conn, patterns_path(context))

      render_click(view, "open_label", %{"label-id" => @label})

      assert has_element?(view, "#label-remove-#{@child}", "Remove label")
      # The owner carries the ID, so it is never the pattern that loses it.
      refute has_element?(view, "#label-remove-#{@label}")

      # Opening the confirm writes nothing.
      render_click(view, "request_remove_label", %{"pattern-id" => @child})

      assert has_element?(view, "#label-remove-dialog[data-open='true']")
      assert text(view, "#label-remove-dialog") =~ "Remove the label on #{@child_name}?"
      assert pattern_label(loaded_pattern(context, @child)) == owner_id(context)

      render_click(view, "remove_label")

      # The write is the one the confirm describes: the child's own pointer, and
      # nothing else. The grouping has no children left, so the list shows the
      # child on its own and the owner as an ordinary pattern.
      assert is_nil(loaded_pattern(context, @child).label_pattern_id)
      assert is_nil(loaded_pattern(context, @label).label_pattern_id)

      refute has_element?(view, "#pattern-label-#{@label}")
      refute has_element?(view, "tr[data-label-role='child']")
      assert has_element?(view, "#pattern-open-#{@child}")
      assert has_element?(view, "#pattern-open-#{@label}")
      refute has_element?(view, "#label-drawer")
    end

    test "leaves the pattern, its stops and its trips in place", context do
      build_scenario(context)
      {:ok, view, _html} = live(context.conn, patterns_path(context))

      render_click(view, "open_label", %{"label-id" => @label})
      render_click(view, "request_remove_label", %{"pattern-id" => @child})
      render_click(view, "remove_label")

      child = loaded_pattern(context, @child)

      assert child.route_pattern_name == @child_name
      assert stop_count(context, child) == @child_stops
      assert trip_count(context, @child) == @child_trips
    end
  end

  # --- fixture ---------------------------------------------------------------
  # One route with three patterns in Direction 0: the owner of `1-0-A`, a child
  # labelled with it, and `1-0-B`, which carries no label.
  defp build_scenario(context) do
    org_id = context.organization.id
    version_id = context.version.id

    route_fixture(org_id, version_id, %{
      route_id: @route_id,
      route_short_name: "1",
      route_long_name: "Lincoln City – Newport"
    })

    stops = insert_stops(org_id, version_id)

    owner =
      route_pattern_fixture(org_id, version_id, %{
        route_id: @route_id,
        route_pattern_id: @label,
        route_pattern_name: @owner_name,
        route_pattern_time_desc: @time_desc,
        direction_id: 0,
        route_pattern_typicality: 1,
        route_pattern_sort_order: 1
      })

    child =
      route_pattern_fixture(org_id, version_id, %{
        route_id: @route_id,
        route_pattern_id: @child,
        route_pattern_name: @child_name,
        direction_id: 0,
        route_pattern_typicality: 0,
        route_pattern_sort_order: 2
      })

    # The owner serves the full order; the child the same route without its last
    # two stops, which is what makes them two stop orders under one ID.
    for {stop_id, position} <- Enum.with_index(Enum.take(stops, @owner_stops), 1) do
      route_pattern_stop_fixture(owner, stop_id, position)
    end

    for {stop_id, position} <- Enum.with_index(Enum.take(stops, @child_stops), 1) do
      route_pattern_stop_fixture(child, stop_id, position)
    end

    label!(child, owner)

    route_pattern_fixture(org_id, version_id, %{
      route_id: @route_id,
      route_pattern_id: @unlabelled,
      route_pattern_name: "Lincoln City – Newport Transit Center",
      direction_id: 0,
      route_pattern_typicality: 0,
      route_pattern_sort_order: 3
    })

    insert_trips(org_id, version_id, child, @child_trips)

    %{owner: owner, child: child}
  end

  defp insert_stops(org_id, version_id) do
    for index <- 1..@owner_stops do
      stop_fixture(org_id, version_id, %{
        stop_id: "S#{index}",
        stop_name: "Line Stop #{index - 1}",
        location_type: 0,
        stop_lat: 44.0 + index * 0.001,
        stop_lon: -124.0
      }).stop_id
    end
  end

  # The child's trips point at its own stored ID, which is the value the export
  # resolves through the label: the owner's while it is labelled. A linked trip
  # carries a timing, so the fixture gives the child one.
  defp insert_trips(org_id, version_id, child, count) do
    timing = timed_pattern_fixture(child, %{name: "Weekday daytime"})

    for index <- 1..count do
      org_id
      |> trip_fixture(version_id, @route_id, %{trip_id: "#{child.route_pattern_id}_T#{index}"})
      |> trip_pattern_metadata_fixture(%{
        route_pattern_id: child.route_pattern_id,
        direction_id: 0,
        timed_pattern_id: timing.id,
        pattern_derivation_state: "linked",
        pattern_derivation_reason: nil
      })
    end
  end

  # A label is written by derivation and review, neither of which casts this
  # column, so the fixture writes the pointer the way those writers do: as a
  # direct update of the never-cast column.
  defp label!(child, owner) do
    {1, nil} =
      Repo.update_all(
        from(p in RoutePattern, where: p.id == ^child.id),
        set: [label_pattern_id: owner.id]
      )

    Repo.get!(RoutePattern, child.id)
  end

  # --- helpers ---------------------------------------------------------------

  defp patterns_path(context),
    do: "/gtfs/#{context.version.id}/routes/#{@route_id}/patterns"

  defp pattern_in(patterns, route_pattern_id) do
    Enum.find(patterns, &(&1.route_pattern_id == route_pattern_id))
  end

  defp loaded_pattern(context, route_pattern_id) do
    Repo.one!(
      from(p in RoutePattern,
        where:
          p.organization_id == ^context.organization.id and
            p.route_pattern_id == ^route_pattern_id,
        select: p
      )
    )
  end

  defp owner_id(context), do: loaded_pattern(context, @label).id

  defp pattern_label(pattern), do: pattern.label_pattern_id

  defp stop_count(_context, pattern) do
    Repo.aggregate(
      from(occurrence in GtfsPlanner.Gtfs.RoutePatternStop,
        where: occurrence.route_pattern_id == ^pattern.id
      ),
      :count,
      :id
    )
  end

  defp trip_count(context, route_pattern_id) do
    Repo.aggregate(
      from(t in Trip,
        where:
          t.organization_id == ^context.organization.id and
            t.route_pattern_id == ^route_pattern_id
      ),
      :count,
      :id
    )
  end

  # The row IDs the list streams, in the order the page rendered them, so the
  # group is checked as a run of rows rather than as three separate elements.
  defp row_ids(view) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#patterns-list tr[id]")
    |> LazyHTML.attribute("id")
    |> List.flatten()
  end

  defp index_of(ids, id) do
    case Enum.find_index(ids, &(&1 == id)) do
      nil -> flunk("expected a row with id #{inspect(id)}, got #{inspect(ids)}")
      index -> index
    end
  end

  defp text(view, selector), do: view |> render() |> text_in(selector)

  defp text_in(html, selector) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(selector)
    |> LazyHTML.text()
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end
end
