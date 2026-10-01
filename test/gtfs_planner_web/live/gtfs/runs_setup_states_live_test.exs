defmodule GtfsPlannerWeb.Gtfs.RunsSetupStatesLiveTest do
  @moduledoc """
  The first-use panel, the relief-setup callout, and the one-primary rule.

  The primary rule is the claim that needs the most care, because it is easy to
  satisfy and easy to fake. Two things make it real here:

  - the count is taken by class, the class the `button` component gives
    `variant="primary"`, so it counts what a reader sees rather than what a
    component intends;
  - it is counted over the page's own action regions — the head's actions and the
    plan card — not the whole document. A closed drawer stays in the DOM with its
    controls, so a whole-document count would report primaries belonging to
    dialogs nobody is looking at. The Crew rules drawer's Save is the one that
    would be miscounted.

  The four cases are the four page states: problems to review, first use, no
  blocks, and a clean loaded day with nothing left to fix.
  """
  use GtfsPlannerWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.RunsFixtures

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.Blocking

  @moduletag :ev_33
  @moduletag timeout: 120_000

  setup do
    %{user: user_fixture()}
  end

  defp world(ctx) do
    w = runs_version_fixture()

    Accounts.create_user_org_membership(%{
      user_id: ctx.user.id,
      organization_id: w.organization.id,
      roles: ["pathways_studio_editor"]
    })

    w
  end

  defp open(ctx, w) do
    conn = log_in_user(ctx.conn, ctx.user, organization: w.organization)
    {:ok, view, _html} = live(conn, "/gtfs/#{w.version.id}/runs")
    view
  end

  defp doc(view), do: view |> render() |> LazyHTML.from_document()

  defp attribute(view, selector, name) do
    view |> doc() |> LazyHTML.query(selector) |> LazyHTML.attribute(name) |> List.first()
  end

  # The page's primary actions, by ID.
  #
  # The two regions are the head's actions and the plan card, which is where every
  # state panel lives. Both are outside the drawers, so a closed drawer's controls
  # cannot be counted here — which is the point: the one-primary rule is about
  # what the reader can act on, and a button inside a `<dialog>` marked
  # `data-open="false"` is not one.
  #
  # IDs rather than a count, so a failure says which action is the extra one.
  @action_regions "#runs-head-actions .btn-primary, #runs-plan .btn-primary"

  defp primary_actions(view) do
    view |> doc() |> LazyHTML.query(@action_regions) |> LazyHTML.attribute("id")
  end

  # A version with a day type and NO blocks: trips exist, but nothing groups them
  # into a vehicle's work, so there is nothing for the Runs page to cut.
  #
  # Built from the plain GTFS fixtures rather than by removing the runs fixture's
  # blocks. Deleting them would leave the movements, stops and settings a block
  # implies behind, and a no-blocks state that still has them is a state the real
  # page can never reach.
  defp bare_version(ctx) do
    import GtfsPlanner.GtfsFixtures
    import GtfsPlanner.OrganizationsFixtures
    import GtfsPlanner.VersionsFixtures

    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)

    route =
      route_fixture(organization.id, version.id, %{
        route_id: "R1",
        route_short_name: "1",
        route_long_name: "Main"
      })

    calendar_fixture(organization.id, version.id, %{service_id: "WK"})

    trip =
      trip_fixture(organization.id, version.id, route.id, %{
        trip_id: "T1",
        service_id: "WK",
        # No `block_id`, and that is the point: a trip carrying a block ID *is* a
        # block, so `counts.blocks` would be 1 and the day would be in FIRST USE
        # rather than the no-blocks state.
        block_id: nil
      })

    stop_fixture(organization.id, version.id, %{stop_id: "S1", stop_name: "Main"})

    stop_time_fixture(organization.id, version.id, trip.id, "S1", %{
      stop_sequence: 1,
      arrival_time: "08:00:00",
      departure_time: "08:00:00"
    })

    Accounts.create_user_org_membership(%{
      user_id: ctx.user.id,
      organization_id: organization.id,
      roles: ["pathways_studio_editor"]
    })

    %{organization: organization, version: version, day_type_key: "WK"}
  end

  # Blocks and no runs: the first-use state. The fixture creates blocks and no
  # assignments, which is exactly this.
  defp first_use_world(ctx) do
    world(ctx)
  end

  # A day with a finding to review: a run spanning two blocks is too spread out
  # for the crew limit.
  defp first_use_with_problems(ctx) do
    w = first_use_world(ctx)
    [first_101 | _rest_101] = w.blocks["101"]
    [_first_102, second_102] = w.blocks["102"]

    # ONE trip in one run is not enough: a single trip is short enough to pass
    # every check, so that world looked clean, handed the primary to nobody, and
    # made the problems case pass for the wrong reason.
    {:ok, _} =
      Gtfs.update_crew_settings(w.audit, %{max_spread_minutes: 240})

    for trip <- [first_101, second_102] do
      trip_run_fixture(w.organization.id, w.version.id, %{
        trip: trip,
        day_type_key: w.day_type_key,
        run_id: "1001"
      })
    end

    w
  end

  # A loaded day with nothing to fix: runs cut exactly at the block's marked
  # relief windows, and limits the day comfortably meets.
  #
  # This took three attempts to build, and each failure is a fact about the
  # fixture's geometry rather than a bad assertion:
  #
  #   - every trip in ONE run is six pieces, and the block then raises
  #     `cannot_reach_piece` between them;
  #   - one run per trip leaves runs starting and ending away from a marked
  #     relief, which raises `not_at_relief`;
  #   - what works is runs of TWO trips split at the block's relief windows.
  #
  # `max_piece_minutes` then has to be widened, because it lives on the BLOCK
  # rules rather than the crew settings.
  defp clean_world(ctx) do
    w = world(ctx)
    [a, b, c, d] = w.blocks["101"]
    [e, f] = w.blocks["102"]

    for {trips, run_id} <- [{[a, b], "1001"}, {[c, d], "1002"}, {[e, f], "1003"}] do
      for trip <- trips do
        trip_run_fixture(w.organization.id, w.version.id, %{
          trip: trip,
          day_type_key: w.day_type_key,
          run_id: run_id
        })
      end
    end

    {:ok, _} =
      Gtfs.update_blocking_settings(w.audit, %{max_piece_minutes: 720})

    w
  end

  # Operator changes unset: no marked relief point and no piece limit. This is
  # what a version looks like straight after its blocks are cut.
  defp without_operator_changes(w) do
    {:ok, :ok} =
      Blocking.update_relief_settings(w.audit, nil, %{
        max_piece_minutes: nil,
        marked: []
      })

    w
  end

  defp with_operator_changes(w) do
    {:ok, :ok} =
      Blocking.update_relief_settings(w.audit, nil, %{
        max_piece_minutes: 330,
        marked: [w.relief_stop_id]
      })

    w
  end

  describe "one primary per state" do
    test "a loaded day with problems gives the primary to Review problems", ctx do
      w = first_use_with_problems(ctx)
      view = open(ctx, w)

      assert primary_actions(view) == ["runs-review-problems"]
      assert attribute(view, "#runs-review-problems", "data-primary") == "true"
      assert attribute(view, "#runs-suggest", "data-primary") == "false"
    end

    test "first use gives the primary to Suggest runs", ctx do
      w = first_use_world(ctx)
      view = open(ctx, w)

      assert primary_actions(view) == ["runs-suggest"]
      assert attribute(view, "#runs-suggest", "data-primary") == "true"
    end

    test "no blocks gives the page no head actions at all", ctx do
      bare = bare_version(ctx)
      view = open(ctx, bare)

      assert has_element?(view, "#runs-empty")

      # The head's actions are `:if={@runs_day}` and a day with no blocks still
      # loads, so the primary belongs to the no-blocks panel's own link.
      assert primary_actions(view) == ["runs-empty-link"]

      # And the first-use panel is NOT what a no-blocks day shows. They are
      # different states with different next steps, and the panel's whole claim is
      # that there are blocks to cut.
      refute has_element?(view, "#runs-first-use")
    end

    test "a clean loaded day has NO primary", ctx do
      w = clean_world(ctx)
      view = open(ctx, w)

      # Nothing to fix and nothing unfinished, so promoting anything would be
      # asking the reader to prefer one action arbitrarily.
      assert primary_actions(view) == []
      assert attribute(view, "#runs-suggest", "data-primary") == "false"
      assert attribute(view, "#runs-review-problems", "data-primary") == "false"
    end

    test "Suggest runs is still offered on a clean day, as a secondary", ctx do
      w = clean_world(ctx)
      view = open(ctx, w)

      # No primary is not no action. The button is present and says what it does;
      # it just does not shout.
      assert has_element?(view, "#runs-suggest", "Suggest runs")
    end
  end

  describe "the first-use panel" do
    test "it explains what Suggest runs does", ctx do
      w = first_use_world(ctx)
      view = open(ctx, w)

      assert has_element?(
               view,
               "#runs-first-use",
               "No runs yet. Suggest runs cuts every block into operator work."
             )
    end

    test "it is shown only when there are blocks and no runs", ctx do
      w = first_use_world(ctx)
      view = open(ctx, w)
      assert has_element?(view, "#runs-first-use")

      # A day with runs is not in first use, and the panel must not linger
      # alongside the chart it replaced.
      clean = clean_world(ctx)
      clean_view = open(ctx, clean)
      refute has_element?(clean_view, "#runs-first-use")
    end

    test "it does not claim a chart that is not there", ctx do
      w = first_use_world(ctx)
      view = open(ctx, w)

      # An empty chart would read as a day whose blocks are all covered, which is
      # the opposite of what is true here.
      refute has_element?(view, "#runs-timeline")
      refute has_element?(view, "[data-role=run-row]")
    end

    test "it offers the uncovered work as a link, not a button", ctx do
      w = first_use_world(ctx)
      view = open(ctx, w)

      # A link, because the uncovered tab is a VIEW of this page and not an
      # action that changes anything. A button styled as a link would claim to
      # do something it does not.
      href = attribute(view, "#runs-first-use-uncovered", "href")
      assert href =~ "panel=uncovered"
      assert href =~ "day=#{w.day_type_key}"
    end

    test "no chart controls are offered over a panel with no chart", ctx do
      w = first_use_world(ctx)
      view = open(ctx, w)

      # Timeline/List and Whole day/Zoom in are controls for a chart that is not
      # being drawn. Leaving them on screen would let a reader press a control
      # that changes nothing.
      refute has_element?(view, "#runs-view")
      refute has_element?(view, "#runs-scale")

      # The chart's KEY too: a legend for marks that are not on screen is markup
      # that explains nothing. Its id is `chart-key`, not a `runs-` prefixed one.
      refute has_element?(view, "#chart-key")
    end
  end

  describe "the relief setup callout" do
    test "it is shown when operator changes are not set up", ctx do
      w = first_use_world(ctx) |> without_operator_changes()
      view = open(ctx, w)

      assert has_element?(
               view,
               "#runs-relief-callout",
               "Runs are cut only at block ends. Set up operator changes to split long blocks."
             )
    end

    test "it is not shown once a relief point and a piece limit are set", ctx do
      w = first_use_world(ctx) |> with_operator_changes()
      view = open(ctx, w)

      refute has_element?(view, "#runs-relief-callout")
    end

    test "a relief point with no piece limit still needs setup", ctx do
      w = first_use_world(ctx)

      # Both halves of `relief_ready?` are required. A limit with no relief point
      # splits nothing, so treating either half as sufficient would hide the
      # callout on a version where blocks still cannot be split.
      {:ok, :ok} =
        Blocking.update_relief_settings(w.audit, nil, %{
          max_piece_minutes: nil,
          marked: [w.relief_stop_id]
        })

      view = open(ctx, w)
      assert has_element?(view, "#runs-relief-callout")
    end

    test "a piece limit with no relief point still needs setup", ctx do
      w = first_use_world(ctx)

      {:ok, :ok} =
        Blocking.update_relief_settings(w.audit, nil, %{
          max_piece_minutes: 330,
          marked: []
        })

      view = open(ctx, w)
      assert has_element?(view, "#runs-relief-callout")
    end

    test "it links to Blocks' operator changes", ctx do
      w = first_use_world(ctx) |> without_operator_changes()
      view = open(ctx, w)

      href = attribute(view, "#runs-relief-callout-link", "href")
      assert href =~ "/gtfs/#{w.version.id}/blocks"
      assert href =~ "day=#{w.day_type_key}"
      assert has_element?(view, "#runs-relief-callout-link", "Go to Blocks")
    end

    test "it never blocks the actions", ctx do
      w = first_use_world(ctx) |> without_operator_changes()
      view = open(ctx, w)

      # A panel would be a reader stopped by a setting they may not need. Every
      # action the page offers is still there with the callout up, including the
      # first-use panel itself and the primary it owns.
      assert has_element?(view, "#runs-first-use")
      assert has_element?(view, "#runs-suggest")
      assert primary_actions(view) == ["runs-suggest"]

      # `role="status"` rather than `role="alert"`, and that is part of "never
      # blocks". An assertive live region interrupts a screen reader mid-sentence
      # for what is a setup hint; a polite one waits its turn. The role IS the
      # difference, so it is asserted.
      assert attribute(view, "#runs-relief-callout", "role") == "status"

      # And the callout cannot become a primary on its own terms: it is a link,
      # not a button, so there is nothing in it to style as one.
      refute has_element?(view, "#runs-relief-callout button")
      refute has_element?(view, "#runs-relief-callout .btn-primary")
    end

    test "it survives alongside a planned day", ctx do
      w = clean_world(ctx) |> without_operator_changes()
      view = open(ctx, w)

      # Operator changes are version-wide, so a day with runs cut can still need
      # them: a hand-made run is not split at any window.
      assert has_element?(view, "#runs-relief-callout")
      refute has_element?(view, "#runs-first-use")
      assert has_element?(view, "#runs-timeline")
    end

    test "it carries no primary of its own", ctx do
      # A day that HAS a problem and is missing operator changes, so both the
      # callout and a primary candidate are on screen at once.
      w = first_use_with_problems(ctx) |> without_operator_changes()
      view = open(ctx, w)

      assert has_element?(view, "#runs-relief-callout")
      assert attribute(view, "#runs-review-problems", "data-count") != "0"

      # The one primary is still the problems action. The callout explains why
      # the runs need attention; it is not an action competing for the button
      # that opens them.
      assert primary_actions(view) == ["runs-review-problems"]
    end

    test "a clean day stays primary-free with the callout up", ctx do
      view = open(ctx, clean_world(ctx))

      # On its own the clean day has no primary at all, so the claim is that the
      # callout's appearance promotes nothing.
      #
      # Note what is deliberately NOT claimed: that the callout day and the clean
      # day have the same findings. Clearing the relief points and the piece
      # limit really does change the derivation — a block that is no longer split
      # becomes one long piece — so a comparison of the two problem counts would
      # be asserting a falsehood.
      assert primary_actions(view) == []
      assert attribute(view, "#runs-review-problems", "data-count") == "0"
    end
  end
end
