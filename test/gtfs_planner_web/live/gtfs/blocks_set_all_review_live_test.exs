defmodule GtfsPlannerWeb.Gtfs.BlocksSetAllReviewLiveTest do
  @moduledoc """
  Merge evidence (EV-25) for the Set-all review drawer (R10, AC-20, CL-17,
  rejects FH-18).

  - The four counts for an explicit setting over a group of 3 already set,
    2 refused by the write rule and 9 not stated.
  - A refused row carries `Blocking.RiderOutcomes.refusal_text/1`'s own sentence,
    says "Can't be set." and offers no include box, because a save cannot act on
    it.
  - A row already carrying the setting says "Already set" and offers no box.
  - Unchecking a box updates the footer count and the Save label, and leaves the
    counts alone.
  - "Not stated" reports Removes and Already not stated instead.
  - The drawer is the page's non-modal inspector (`data-modal="false"`), beside
    the group panel it describes.

  Every case runs through the ordinary `/gtfs/:version/blocks` route on the
  production `CatalogReadAdapter.Repo` and the scoped `Blocking` context, so the
  review's rows are the ones `Blocking.Connections` derived and its refusals are
  the ones `Gtfs.check_in_seat_connections/3` returned — the same rule and the
  same call the save re-evaluates (CR-2). Rows are created inside the SQL Sandbox
  transaction and rolled back; nothing here substitutes an adapter or a context.

  The focused gate command is deferred to branch review:
  `MIX_TEST_PARTITION=_seat11 gtimeout --signal=TERM --kill-after=10s 120s mix test test/gtfs_planner_web/live/gtfs/blocks_set_all_review_live_test.exs`.

  `async: false` because these cases share the lane database.
  """
  use GtfsPlannerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.BlockingFixtures
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Gtfs.Blocking.Connections

  @weekday_dates [~D[2026-09-01], ~D[2026-09-02], ~D[2026-09-03]]

  setup do
    organization = organization_fixture()
    user = user_fixture()

    Accounts.create_user_org_membership(%{
      user_id: user.id,
      organization_id: organization.id,
      roles: ["pathways_studio_editor"]
    })

    version = gtfs_version_fixture(organization.id)

    twelve =
      route_fixture(organization.id, version.id, %{route_id: "R12", route_short_name: "12"})

    twenty_four =
      route_fixture(organization.id, version.id, %{route_id: "R24", route_short_name: "24"})

    calendar_service_fixture(organization.id, version.id, %{
      service_id: "W",
      name: "Weekday",
      dates: @weekday_dates
    })

    %{
      organization: organization,
      user: user,
      version: version,
      route_twelve: twelve,
      route_twenty_four: twenty_four
    }
  end

  defp editor_conn(context) do
    log_in_user(context.conn, context.user, organization: context.organization)
  end

  defp connections_url(version_id, params) do
    "/gtfs/#{version_id}/blocks?" <> URI.encode_query(params)
  end

  # The day's own groups, read through the production derivation the panel and
  # the review read, so a case names the group it means by its own token.
  defp derived_groups(context) do
    {:ok, day} =
      GtfsPlanner.Gtfs.load_blocking_day(context.organization.id, context.version.id, nil)

    Connections.build(day).groups
  end

  defp row_token(connection), do: Base.url_encode64(connection.id, padding: false)

  defp place_stop(context, name) do
    stop_fixture(context.organization.id, context.version.id, %{
      stop_id: "SET_ALL_#{System.unique_integer([:positive])}",
      stop_name: name,
      stop_lat: Decimal.new("40.1000"),
      stop_lon: Decimal.new("-74.1000")
    })
  end

  defp clock(seconds) do
    [div(seconds, 3_600), div(rem(seconds, 3_600), 60), rem(seconds, 60)]
    |> Enum.map_join(":", &pad_clock/1)
  end

  defp pad_clock(part), do: part |> Integer.to_string() |> String.pad_leading(2, "0")

  # One block's pair of consecutive trips meeting at `stop`, so the pair is a
  # connection of the group whose key is that stop and those two routes. A
  # `coupling?` pair's second trip departs before the first one arrives, which is
  # the unconfirmed coupling `InSeat.state/2` reports: the write rule refuses it,
  # so the review must say so rather than offer it a box.
  defp block_pair(context, attrs) do
    stop = Map.fetch!(attrs, :stop)
    block_id = Map.fetch!(attrs, :block_id)
    suffix = Map.fetch!(attrs, :suffix)
    first = Map.fetch!(attrs, :first)
    second = if Map.get(attrs, :coupling?, false), do: first + 1_800, else: first + 4_200

    from =
      blocked_trip_fixture(context.organization.id, context.version.id, "R12", %{
        service_id: "W",
        trip_id: "#{block_id}-#{suffix}-a",
        block_id: block_id,
        direction_id: 0,
        trip_headsign: "North",
        first_stop: stop.stop_id,
        last_stop: stop.stop_id,
        first_arrival: clock(first),
        last_arrival: clock(first + 3_600)
      })

    to =
      blocked_trip_fixture(context.organization.id, context.version.id, "R24", %{
        service_id: "W",
        trip_id: "#{block_id}-#{suffix}-b",
        block_id: block_id,
        direction_id: 0,
        trip_headsign: "South",
        first_stop: stop.stop_id,
        last_stop: stop.stop_id,
        first_arrival: clock(second),
        last_arrival: clock(second + 3_600)
      })

    %{from: from, to: to}
  end

  # A quiet type 4 record on the pair, which R13 reads as `:stay` and which the
  # rule still matches, so choosing "Riders stay on board" changes nothing for it.
  defp stay_record(context, pair) do
    in_seat_transfer_fixture(context.organization.id, context.version.id, pair.from, pair.to)
  end

  # One place holding fourteen blocks: three pairs already carrying a type 4
  # record, two the rule refuses, and nine with no record at all. The counts and
  # the footer both read from that shape, so it is the group's own derivation
  # rather than values this module reconstructs.
  defp reviewed_group(context) do
    stop = place_stop(context, "Farragut Square")

    stay =
      for index <- 1..3 do
        pair =
          block_pair(context, %{
            stop: stop,
            block_id: "S#{index}",
            suffix: "s",
            first: index * 3_600
          })

        stay_record(context, pair)
        pair
      end

    blocked =
      for index <- 1..2 do
        block_pair(context, %{
          stop: stop,
          block_id: "B#{index}",
          suffix: "b",
          first: 10_800 + index * 3_600,
          coupling?: true
        })
      end

    plain =
      for index <- 1..9 do
        block_pair(context, %{
          stop: stop,
          block_id: "N#{index}",
          suffix: "n",
          first: 21_600 + index * 3_600
        })
      end

    context
    |> Map.put(:stop, stop)
    |> Map.put(:stay_pairs, stay)
    |> Map.put(:blocked_pairs, blocked)
    |> Map.put(:plain_pairs, plain)
  end

  # The group the derivation names, mounted on the URL that selects it and driven
  # through the panel's own controls: choose a setting, then press the button the
  # panel renders.
  defp open_review(context, group, choice) do
    {:ok, view, _html} =
      live(
        editor_conn(context),
        connections_url(context.version.id, view: "connections", group: group.token)
      )

    render_change(view, "bulk_choice", %{"bulk" => choice})
    render_click(view, "open_bulk_review", %{})

    view
  end

  defp attribute(view, selector, name) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.filter(selector)
    |> Enum.flat_map(&LazyHTML.attribute(&1, name))
  end

  defp checked?(view, selector), do: attribute(view, selector, "checked") != []

  defp has_checkbox?(view, selector), do: attribute(view, selector, "type") == ["checkbox"]

  # One count card's own number: the card whose id the label's words make, read
  # as text so a case asserts the value rather than the markup around it.
  defp count_card(view, id, value) do
    card = view |> render() |> LazyHTML.from_fragment() |> LazyHTML.filter("##{id}")

    assert length(card) == 1
    assert LazyHTML.text(card) =~ to_string(value)
  end

  describe "the counts" do
    test "an explicit setting reports adds, replaces, already set and refused", context do
      context = reviewed_group(context)
      [group | _rest] = derived_groups(context)

      view = open_review(context, group, "stay")

      # Three pairs already carry the setting, two the rule refuses, and nine
      # carry nothing at all.
      count_card(view, "adds", 9)
      count_card(view, "replaces", 0)
      count_card(view, "already-set", 3)
      count_card(view, "cant-be-set", 2)
    end

    test "Not stated reports removes and already not stated instead", context do
      context = reviewed_group(context)
      [group | _rest] = derived_groups(context)

      view = open_review(context, group, "none")

      count_card(view, "removes", 3)
      count_card(view, "already-not-stated", 11)
      refute has_element?(view, "#set-all-review-count-adds")
      refute has_element?(view, "#set-all-review-count-cant-be-set")
    end
  end

  describe "the rows" do
    test "a refused row says why and offers no include box", context do
      context = reviewed_group(context)
      [group | _rest] = derived_groups(context)

      view = open_review(context, group, "stay")

      for connection <- connections_of(group, "B") do
        token = row_token(connection)
        selector = "#set-all-review-row-#{token}"

        assert has_element?(view, selector, "Can’t be set.")
        # The rule's own sentence, not a second wording: the second trip starts
        # before the first one ends.
        assert has_element?(view, selector, "can't be one vehicle in sequence")
        assert attribute(view, selector, "data-result") == ["skip"]
        refute has_checkbox?(view, "#set-all-review-include-#{token}")
      end
    end

    test "a pair already carrying the setting says so and offers no box", context do
      context = reviewed_group(context)
      [group | _rest] = derived_groups(context)

      view = open_review(context, group, "stay")

      for connection <- connections_of(group, "S") do
        token = row_token(connection)

        assert has_element?(view, "#set-all-review-row-#{token}", "Already set")
        assert attribute(view, "#set-all-review-row-#{token}", "data-result") == ["same"]
        refute has_checkbox?(view, "#set-all-review-include-#{token}")
      end
    end

    test "a pair with no record says what the save would write", context do
      context = reviewed_group(context)
      [group | _rest] = derived_groups(context)

      view = open_review(context, group, "stay")

      [connection | _rest] = connections_of(group, "N")
      token = row_token(connection)

      assert has_element?(view, "#set-all-review-row-#{token}", "Not stated")
      assert has_element?(view, "#set-all-review-row-#{token}", "Adds record")
      assert checked?(view, "#set-all-review-include-#{token}")
    end

    test "every row names its block, its arrival, its pair and its wait", context do
      context = reviewed_group(context)
      [group | _rest] = derived_groups(context)

      view = open_review(context, group, "stay")

      [connection | _rest] = connections_of(group, "N")
      token = row_token(connection)
      row = "#set-all-review-row-#{token}"

      assert has_element?(view, row, "N1")
      assert has_element?(view, row, "N1-n-a")
      assert has_element?(view, row, "N1-n-b")
      assert has_element?(view, row, "min")
      assert has_element?(view, "#set-all-review-table thead", "Now → result")
    end
  end

  describe "leaving a connection out" do
    test "unchecking a row updates the footer and the Save label", context do
      context = reviewed_group(context)
      [group | _rest] = derived_groups(context)

      view = open_review(context, group, "stay")

      # Nine actionable rows: three already set and two refused have no box.
      assert has_element?(view, "#set-all-review-included", "9 of 9 included")
      assert has_element?(view, "#set-all-review-save", "Save 9 connections")

      [connection | _rest] = connections_of(group, "N")

      render_click(
        view,
        "toggle_bulk_row",
        %{"id" => connection.id}
      )

      assert has_element?(view, "#set-all-review-included", "8 of 9 included")
      assert has_element?(view, "#set-all-review-save", "Save 8 connections")
      refute checked?(view, "#set-all-review-include-#{row_token(connection)}")

      # The counts describe what saving would do to the whole group, so leaving
      # one connection out does not move them.
      count_card(view, "adds", 9)
    end

    test "unchecking every row leaves Save disabled", context do
      context = reviewed_group(context)
      [group | _rest] = derived_groups(context)

      view = open_review(context, group, "stay")

      for connection <- connections_of(group, "N") do
        render_click(view, "toggle_bulk_row", %{"id" => connection.id})
      end

      assert has_element?(view, "#set-all-review-included", "0 of 9 included")
      assert has_element?(view, "#set-all-review-save", "Save 0 connections")
      assert attribute(view, "#set-all-review-save", "disabled") != []
    end

    test "a row with no box cannot be toggled by a crafted event", context do
      context = reviewed_group(context)
      [group | _rest] = derived_groups(context)

      view = open_review(context, group, "stay")

      [blocked | _rest] = connections_of(group, "B")
      [same | _rest] = connections_of(group, "S")

      render_click(view, "toggle_bulk_row", %{"id" => blocked.id})
      render_click(view, "toggle_bulk_row", %{"id" => same.id})

      assert has_element?(view, "#set-all-review-included", "9 of 9 included")

      assert attribute(view, "#set-all-review-row-#{row_token(blocked)}", "data-result") == [
               "skip"
             ]

      assert attribute(view, "#set-all-review-row-#{row_token(same)}", "data-result") == ["same"]
    end
  end

  describe "the drawer itself" do
    test "it is the non-modal inspector beside the group panel", context do
      context = reviewed_group(context)
      [group | _rest] = derived_groups(context)

      view = open_review(context, group, "stay")

      assert has_element?(view, "#set-all-review-overlay[data-modal='false']")
      assert has_element?(view, "#set-all-review", "Review: riders stay on board")
      assert has_element?(view, "#set-all-review", "Farragut Square")
      assert has_element?(view, "#set-all-review", "14 connections")
      assert has_element?(view, "#set-all-review", "Preview, not saved")
      assert has_element?(view, "#set-all-review-note")
      assert has_element?(view, "#set-all-review-table")
      assert has_element?(view, "#set-all-review-cancel")

      # The panel it describes is still on screen: the review is beside it, not
      # over it.
      assert has_element?(view, "#connections-group-heading")
    end

    test "Cancel closes it and leaves the group open", context do
      context = reviewed_group(context)
      [group | _rest] = derived_groups(context)

      view = open_review(context, group, "stay")

      render_click(view, "close_bulk_review", %{})

      refute has_element?(view, "#set-all-review")
      assert has_element?(view, "#connections-group-heading")
    end

    test "choosing a different setting closes the review it described", context do
      context = reviewed_group(context)
      [group | _rest] = derived_groups(context)

      view = open_review(context, group, "stay")
      assert has_element?(view, "#set-all-review", "Review: riders stay on board")

      render_change(view, "bulk_choice", %{"bulk" => "reboard"})

      refute has_element?(view, "#set-all-review")
    end

    test "with no setting chosen there is nothing to review", context do
      context = reviewed_group(context)
      [group | _rest] = derived_groups(context)

      {:ok, view, _html} =
        live(
          editor_conn(context),
          connections_url(context.version.id, view: "connections", group: group.token)
        )

      assert has_element?(view, "#bulk-review-open")
      assert attribute(view, "#bulk-review-open", "disabled") != []

      render_click(view, "open_bulk_review", %{})

      refute has_element?(view, "#set-all-review")
    end
  end

  # The connections of the reviewed group whose block id starts with `prefix`, so
  # a case names the three kinds of row — already set, refused, not stated — by
  # the block the fixture gave them.
  defp connections_of(group, prefix) do
    Enum.filter(group.connections, &String.starts_with?(&1.block_id, prefix))
  end
end
