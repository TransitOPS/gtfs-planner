defmodule GtfsPlannerWeb.Gtfs.RoutePatternFitReviewTest do
  @moduledoc false
  # EV-30: the fit review panel (CL-24, CL-25; FH-24, FH-25). The report
  # itself is the hook's geometry, so every case here drives the panel through
  # the production path that receives it — `render_hook/3` on the rendered
  # pattern page — and the buttons are clicked the way an editor clicks them.
  # Expected values are literals from the prototype's review states and the
  # GTFS reference, never read back from the code under test.
  use GtfsPlannerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Accounts

  setup :editor_scope

  describe "the direction finding" do
    test "a reversed line offers Reverse line and blocks the draft", ctx do
      {route, pattern} = corridor_pattern(ctx)
      view = open_alignment(ctx, route, pattern)

      render_hook(view, "alignment_fit_result", fit_params(%{"direction" => "reversed"}))

      # The finding says which way the line runs, in this pattern's own stops.
      assert has_element?(view, "#fit-direction-reversed", "This line runs the other way")
      assert has_element?(view, "#fit-direction-reversed", "File Stop 1")
      assert has_element?(view, "#fit-direction-reversed", "File Stop 9")
      assert has_element?(view, "#fit-reverse", "Reverse line")

      # AC-24: the draft is blocked, and the reason is on screen, not in a
      # tooltip nobody sees.
      assert has_element?(view, "#fit-create-draft[disabled]")
      assert has_element?(view, "#fit-footer-note", "Reverse the line to continue")
      assert has_element?(view, "#fit-footer-note", "runs the other way")
    end

    test "clicking Reverse line asks the hook to report the line the other way", ctx do
      {route, pattern} = corridor_pattern(ctx)
      view = open_alignment(ctx, route, pattern)

      render_hook(view, "alignment_fit_result", fit_params(%{"direction" => "reversed"}))
      view |> element("#fit-reverse") |> render_click()

      # The geometry is the hook's (INV-5): the server only asks.
      assert_push_event(view, "alignment:reverse_file_line", %{})
      # The review itself stays up: the answer comes back as a new report.
      assert has_element?(view, "#file-fit-review")
    end

    test "a line that cannot say which way it runs is reported, never blocked", ctx do
      {route, pattern} = corridor_pattern(ctx)
      view = open_alignment(ctx, route, pattern)

      render_hook(view, "alignment_fit_result", fit_params(%{"direction" => "unknown"}))

      # Step 28's contract: the loop case is not a reversal. The panel says it
      # cannot tell and leaves the draft alone.
      assert has_element?(view, "#fit-direction-unknown", "runs the same way at both ends")
      refute has_element?(view, "#fit-direction-reversed")
      refute has_element?(view, "#fit-reverse")
      assert has_element?(view, "#fit-create-draft:not([disabled])")
    end

    test "a line running this pattern's way says so without a reversal", ctx do
      {route, pattern} = corridor_pattern(ctx)
      view = open_alignment(ctx, route, pattern)

      render_hook(view, "alignment_fit_result", fit_params(%{}))

      refute has_element?(view, "#fit-direction-reversed")
      refute has_element?(view, "#fit-direction-unknown")
      assert has_element?(view, "#fit-create-draft:not([disabled])")
      assert has_element?(view, "#fit-footer-note", "Nothing is saved until you save")
    end
  end

  describe "the headline and the far stops" do
    test "the headline counts the stops within 330 ft of the line", ctx do
      {route, pattern} = corridor_pattern(ctx)
      view = open_alignment(ctx, route, pattern)

      render_hook(view, "alignment_fit_result", fit_params(%{}))

      assert has_element?(view, "#file-fit-headline", "8 of 9")
      assert has_element?(view, "#file-fit-headline", "stops within 330 ft")
      assert has_element?(view, "#file-fit-length", "2.5 km")
    end

    test "one far stop is named with its distance, others are counted", ctx do
      {route, pattern} = corridor_pattern(ctx)
      view = open_alignment(ctx, route, pattern)

      render_hook(view, "alignment_fit_result", fit_params(%{}))

      assert has_element?(view, "#fit-far", "more than 330 ft")
      # 145.25 m is 480 ft to the nearest 10.
      assert has_element?(view, "#fit-far-8", "File Stop 8, 480 ft from the line")

      render_hook(
        view,
        "alignment_fit_result",
        fit_params(%{
          "within" => 7,
          "far" => [
            %{"position" => 3, "stop_id" => "FST_3", "distance_m" => 145.25},
            %{"position" => 8, "stop_id" => "FST_8", "distance_m" => 400.0}
          ]
        })
      )

      assert has_element?(view, "#fit-far", "2 stops are more than 330 ft from the line")
      assert has_element?(view, "#fit-far-3")
      assert has_element?(view, "#fit-far-8")
    end

    test "a line every stop sits on says so and keeps the draft", ctx do
      {route, pattern} = corridor_pattern(ctx)
      view = open_alignment(ctx, route, pattern)

      render_hook(
        view,
        "alignment_fit_result",
        fit_params(%{"far" => [], "within" => 9})
      )

      assert has_element?(view, "#fit-ok", "Every stop is on the line")
      refute has_element?(view, "#fit-far")
      assert has_element?(view, "#fit-create-draft:not([disabled])")
    end
  end

  describe "the ends finding" do
    test "a line that stops short names the last stop it misses", ctx do
      {route, pattern} = corridor_pattern(ctx)
      view = open_alignment(ctx, route, pattern)

      render_hook(view, "alignment_fit_result", fit_params(%{"reaches_end" => false}))

      assert has_element?(view, "#fit-end", "The line ends before File Stop 9")
      assert has_element?(view, "#fit-end", "without a path")
      refute has_element?(view, "#fit-start")
    end

    test "a line that starts late names the first stop it misses", ctx do
      {route, pattern} = corridor_pattern(ctx)
      view = open_alignment(ctx, route, pattern)

      render_hook(view, "alignment_fit_result", fit_params(%{"reaches_start" => false}))

      assert has_element?(view, "#fit-start", "The line starts after File Stop 1")
      refute has_element?(view, "#fit-end")
    end

    test "a line that misses both ends says so twice", ctx do
      {route, pattern} = corridor_pattern(ctx)
      view = open_alignment(ctx, route, pattern)

      render_hook(
        view,
        "alignment_fit_result",
        fit_params(%{"reaches_start" => false, "reaches_end" => false})
      )

      assert has_element?(view, "#fit-start")
      assert has_element?(view, "#fit-end")
      # Missing an end is a warning about the line, never a block on the
      # draft: the sections that have no path can be generated next.
      assert has_element?(view, "#fit-create-draft:not([disabled])")
    end
  end

  describe "the footer" do
    test "Create editable draft asks the hook to draft and closes the panel", ctx do
      {route, pattern} = corridor_pattern(ctx)
      view = open_alignment(ctx, route, pattern)

      render_hook(view, "alignment_fit_result", fit_params(%{}))
      assert has_element?(view, "#file-import-restart", "Choose another file")

      view |> element("#fit-create-draft") |> render_click()

      # AC-25: the draft is the hook's and the panel hands the editor back to
      # the section list. Nothing is written until Save.
      assert_push_event(view, "alignment:file_draft", %{})
      refute render(view) =~ "id=\"file-fit-review\""
      assert has_element?(view, "#alignment-task")
    end

    test "a forged draft against a reversed fit pushes nothing", ctx do
      {route, pattern} = corridor_pattern(ctx)
      view = open_alignment(ctx, route, pattern)

      render_hook(view, "alignment_fit_result", fit_params(%{"direction" => "reversed"}))

      render_click(view, "alignment_create_file_draft", %{})

      refute_push_event(view, "alignment:file_draft", %{})
      assert has_element?(view, "#fit-create-draft[disabled]")
    end

    test "a forged reverse before any report pushes nothing", ctx do
      {route, pattern} = corridor_pattern(ctx)
      view = open_alignment(ctx, route, pattern)

      render_click(view, "alignment_reverse_file_line", %{})

      refute_push_event(view, "alignment:reverse_file_line", %{})
      assert has_element?(view, "#alignment-task")
    end
  end

  test "leaving the panel drops the fit with it", ctx do
    {route, pattern} = corridor_pattern(ctx)
    view = open_alignment(ctx, route, pattern)

    render_hook(view, "alignment_fit_result", fit_params(%{}))
    assert has_element?(view, "#file-fit-review")

    view |> element("#file-import-restart") |> render_click()

    # The report described one file line; choosing another file drops it.
    refute render(view) =~ "id=\"file-fit-review\""
    assert has_element?(view, "#file-import-panel", "Choose a file")
  end

  # --- fixtures -------------------------------------------------------------

  defp editor_scope(%{conn: conn}) do
    organization =
      organization_fixture(%{alias: "fit-review-#{System.system_time(:nanosecond)}"})

    user =
      user_fixture(%{email: "fit-review-#{System.unique_integer([:positive])}@example.com"})

    Accounts.create_user_org_membership(%{
      user_id: user.id,
      organization_id: organization.id,
      roles: ["pathways_studio_editor"]
    })

    version = gtfs_version_fixture(organization.id)
    conn = log_in_user(conn, user, organization: organization)

    %{conn: conn, user: user, organization: organization, version: version}
  end

  # Nine stops on one meridian, a kilometre and a half apart, so every finding
  # in the review has a stop to name.
  defp corridor_pattern(%{organization: organization, version: version}) do
    route =
      route_fixture(organization.id, version.id, %{
        route_id: "FIT1",
        route_short_name: "FIT1",
        route_long_name: "FIT1 corridor"
      })

    for index <- 1..9 do
      stop_fixture(organization.id, version.id, %{
        stop_id: "FST_#{index}",
        stop_name: "File Stop #{index}",
        stop_lat: Decimal.new("42.#{3560 + (index - 1) * 25}"),
        stop_lon: Decimal.new("-71.0637")
      })
    end

    pattern =
      route_pattern_fixture(organization.id, version.id, %{
        route_id: route.route_id,
        route_pattern_id: "P-FIT-A",
        route_pattern_name: "P-FIT-A",
        direction_id: 0
      })

    for index <- 1..9 do
      route_pattern_stop_fixture(pattern, "FST_#{index}", index)
    end

    {route, pattern}
  end

  # Nine visits, one of them 145.25 m off the line: eight within 100 m, so the
  # headline reads "8 of 9".
  defp fit_params(overrides) do
    Map.merge(
      %{
        "direction" => "same",
        "reaches_start" => true,
        "reaches_end" => true,
        "far" => [%{"position" => 8, "stop_id" => "FST_8", "distance_m" => 145.25}],
        "within" => 8,
        "visit_count" => 9,
        "length_m" => 2543.7
      },
      overrides
    )
  end

  defp open_alignment(%{conn: conn, version: version}, route, pattern) do
    path =
      "/gtfs/#{version.id}/routes/#{route.route_id}/patterns/#{pattern.route_pattern_id}?task=alignment"

    {:ok, view, _html} = live(conn, path)

    assert has_element?(view, "#alignment-task")
    assert has_element?(view, "#alignment-open-file-import")

    view
  end
end
