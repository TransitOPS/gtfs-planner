defmodule GtfsPlannerWeb.Gtfs.BlocksChecksInSeatLiveTest do
  # The Checks drawer's two in-seat cleanup sections and their removals, observed
  # through the ordinary `/gtfs/:version/blocks` route on the production
  # `CatalogReadAdapter.Repo` and the scoped `Blocking` context. Rows are created
  # inside the SQL Sandbox transaction and rolled back; nothing here substitutes
  # an adapter or a fake day.
  use GtfsPlannerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.BlockingFixtures
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Gtfs.Transfer
  alias GtfsPlanner.Repo

  import Ecto.Query

  defp editor_scope(_context) do
    organization = organization_fixture()
    user = user_fixture()

    Accounts.create_user_org_membership(%{
      user_id: user.id,
      organization_id: organization.id,
      roles: ["pathways_studio_editor"]
    })

    version = gtfs_version_fixture(organization.id)

    route =
      route_fixture(organization.id, version.id, %{
        route_id: "R1",
        route_short_name: "1",
        route_long_name: "Riverside Line"
      })

    %{user: user, organization: organization, version: version, route: route}
  end

  defp blocks_path(version_id), do: "/gtfs/#{version_id}/blocks"

  defp editor_conn(context) do
    log_in_user(context.conn, context.user, organization: context.organization)
  end

  defp calendar(context, service_id, name, attrs \\ %{}) do
    calendar_service_fixture(
      context.organization.id,
      context.version.id,
      Map.merge(Enum.into(attrs, %{}), %{service_id: service_id, name: name})
    )
  end

  defp trip(context, attrs) do
    attrs = Map.new(attrs)
    route_id = Map.get(attrs, :route, context.route.route_id)
    {first, attrs} = Map.pop(attrs, :first, "08:00:00")
    {last, attrs} = Map.pop(attrs, :last, "09:00:00")

    blocked_trip_fixture(
      context.organization.id,
      context.version.id,
      route_id,
      attrs
      |> Map.delete(:route)
      |> Map.put_new(:service_id, "WK")
      |> Map.put_new(:trip_id, "trip_#{System.unique_integer([:positive])}")
      |> Map.put(:first_arrival, first)
      |> Map.put(:last_arrival, last)
    )
  end

  # One day type holding both of AC-21's scopes: "Remove {k} records that no
  # longer match" is k = every row of the day whose state is `{:stale, _}`,
  # whether a gap of the day hosts it or not, while "This version · {m}" is
  # `Blocking.unmatched_in_seat_records/2`, the rows stale for the three reasons
  # no block can reach. A no-block row running on the day belongs to both:
  #
  #   * `a -> b` is one gap of block 101 carrying two records, so the connection
  #     needs a choice. Neither record is stale, which is what "conflicts
  #     excluded" in the {k} definition asks for;
  #   * `e -> f` is a second gap of block 101 whose single record drifted off
  #     the stops, so it is `{:stale, :stops_changed}` and joins {k} only;
  #   * `a -> c` and `b -> d` name trips with no block, so each is
  #     `{:stale, :no_block}` with no gap of this day to open, and each is in
  #     {k} and among the version's unmatched records.
  defp in_seat_day(context) do
    calendar(context, "WK", "Weekday")

    # `a` and `b` share block 101 and are consecutive in it, so `a -> b` is a
    # real gap. `e` and `f` are the block's next pair. `c` and `d` are blocked by
    # nothing at all.
    a = trip(context, %{trip_id: "a", block_id: "101", first: "06:00:00", last: "07:00:00"})
    b = trip(context, %{trip_id: "b", block_id: "101", first: "08:00:00", last: "09:00:00"})
    e = trip(context, %{trip_id: "e", block_id: "101", first: "10:00:00", last: "11:00:00"})
    f = trip(context, %{trip_id: "f", block_id: "101", first: "12:00:00", last: "13:00:00"})
    c = trip(context, %{trip_id: "c", first: "14:00:00", last: "15:00:00"})
    d = trip(context, %{trip_id: "d", first: "16:00:00", last: "17:00:00"})

    stay = in_seat_transfer_fixture(context.organization.id, context.version.id, a, b)

    # A second record for the same pair has to differ in a column the transfers
    # key covers, or the unique index makes the pair one row. Drifting the stops
    # would make this record `{:stale, :stops_changed}` and put it in {k}, which
    # is the one thing the day-type removal excludes, so the second row differs
    # by its stored route instead: `InSeat.state/2` compares stops, not routes,
    # so both rows still match the block and the pair is a choice, not a stale
    # row.
    reboard =
      transfer_fixture(context.organization.id, context.version.id, %{
        from_trip_id: a.trip_id,
        to_trip_id: b.trip_id,
        from_stop_id: stay.from_stop_id,
        to_stop_id: stay.to_stop_id,
        from_route_id: "CONFLICT_OTHER",
        transfer_type: 5
      })

    # The second gap's only record, stored off the stop the block actually ends
    # at, so it reads `{:stale, :stops_changed}` on a gap of this day.
    drifted =
      transfer_fixture(context.organization.id, context.version.id, %{
        from_trip_id: e.trip_id,
        to_trip_id: f.trip_id,
        to_stop_id: "DRIFTED_OLD",
        transfer_type: 4
      })

    stale_a =
      transfer_fixture(context.organization.id, context.version.id, %{
        from_trip_id: a.trip_id,
        to_trip_id: c.trip_id,
        transfer_type: 4
      })

    stale_b =
      transfer_fixture(context.organization.id, context.version.id, %{
        from_trip_id: b.trip_id,
        to_trip_id: d.trip_id,
        transfer_type: 4
      })

    %{stay: stay, reboard: reboard, drifted: drifted, stale_a: stale_a, stale_b: stale_b}
  end

  defp open_checks(view) do
    view |> element("#blocks-review-checks") |> render_click()
    view
  end

  defp count(view, selector) do
    view |> render() |> LazyHTML.from_fragment() |> LazyHTML.query(selector) |> Enum.count()
  end

  describe "the Checks drawer's in-seat sections" do
    setup :editor_scope

    test "the day type lists its conflicting and stale records and counts them apart",
         %{version: version} = context do
      %{stay: stay, drifted: drifted, stale_a: stale_a, stale_b: stale_b} = in_seat_day(context)

      conn = editor_conn(context)
      {:ok, view, _html} = live(conn, blocks_path(version.id))

      view = open_checks(view)

      # Four rows need review - one conflicting pair, one stale row on a gap of
      # this day and two stale rows no gap hosts - and the removal counts the
      # three stale ones.
      assert has_element?(
               view,
               "#checks-in-seat",
               "In-seat records that need review \u00b7 4"
             )

      assert count(view, "#checks-in-seat-entries > li") == 4

      assert has_element?(view, "#checks-in-seat-entries [data-kind='conflict']", "Block 101")

      assert has_element?(
               view,
               "#checks-in-seat-entries [data-kind='conflict']",
               "trip a \u2192 b"
             )

      assert has_element?(
               view,
               "#checks-in-seat-entries [data-kind='conflict']",
               "Two records disagree \u00b7 choose one setting"
             )

      # A stale record no gap of this day hosts names its pair and its own
      # reason, and offers the trip drawer rather than a connection.
      assert has_element?(view, "#checks-in-seat-stale-#{stale_a.id}", "Trip a \u2192 c")
      assert has_element?(view, "#checks-in-seat-stale-#{stale_b.id}", "Trip b \u2192 d")

      assert has_element?(
               view,
               "#checks-in-seat-stale-#{stale_a.id}",
               "A trip has no block."
             )

      # A gap of this day hosts the drifted row, so it opens its connection
      # rather than a trip.
      assert has_element?(view, "#checks-in-seat-stale-#{drifted.id}", "trip e \u2192 f")

      assert has_element?(
               view,
               "#checks-in-seat-stale-#{drifted.id}",
               "The record's stops no longer match where these trips end and start."
             )

      assert has_element?(
               view,
               "#checks-remove-stale",
               "Remove 3 records that no longer match"
             )

      assert has_element?(
               view,
               "#checks-remove-stale ~ p",
               "The disagreeing pair needs a choice instead."
             )

      # The two records of the conflicting pair are listed as a choice, never as
      # stale rows, which is what keeps them out of {k}.
      refute has_element?(view, "#checks-in-seat-stale-#{stay.id}")
    end

    test "the version section lists the records no block reaches with their reason",
         %{version: version} = context do
      %{stale_a: stale_a, stale_b: stale_b} = in_seat_day(context)

      conn = editor_conn(context)
      {:ok, view, _html} = live(conn, blocks_path(version.id))

      view = open_checks(view)

      assert has_element?(
               view,
               "#checks-in-seat-version",
               "This version \u00b7 2 in-seat records don't match any block"
             )

      assert has_element?(view, "#checks-unmatched-#{stale_a.id}", "Trip a \u2192 c")
      assert has_element?(view, "#checks-unmatched-#{stale_b.id}", "Trip b \u2192 d")

      assert has_element?(
               view,
               "#checks-unmatched-#{stale_a.id}",
               "Neither trip has a block."
             )

      # The version's own wording of the setting, as the trip drawer names it.
      assert has_element?(view, "#checks-unmatched-#{stale_a.id}", "riders stay on board")
      assert has_element?(view, "#checks-remove-unmatched", "Remove 2 records")
    end

    test "one stale record is named in the singular", %{version: version} = context do
      calendar(context, "WK", "Weekday")

      a = trip(context, %{trip_id: "a", block_id: "101", first: "06:00:00", last: "07:00:00"})
      b = trip(context, %{trip_id: "b", block_id: "101", first: "08:00:00", last: "09:00:00"})

      _drifted =
        transfer_fixture(context.organization.id, context.version.id, %{
          from_trip_id: a.trip_id,
          to_trip_id: b.trip_id,
          to_stop_id: "DRIFTED_OLD",
          transfer_type: 4
        })

      conn = editor_conn(context)
      {:ok, view, _html} = live(conn, blocks_path(version.id))

      view = open_checks(view)

      assert has_element?(view, "#checks-remove-stale", "Remove 1 record that no longer matches")

      view |> element("#checks-remove-stale") |> render_click()

      assert has_element?(view, "#remove-stale-dialog", "Remove 1 in-seat record?")
      assert has_element?(view, "#remove-stale-dialog", "This record no longer matches")
      assert has_element?(view, "#remove-stale-dialog-confirm", "Remove 1 record")
    end

    test "a version with nothing unmatched says so and offers no question",
         %{version: version} = context do
      calendar(context, "WK", "Weekday")

      a = trip(context, %{trip_id: "a", block_id: "101", first: "06:00:00", last: "07:00:00"})
      b = trip(context, %{trip_id: "b", block_id: "101", first: "08:00:00", last: "09:00:00"})

      _matching = in_seat_transfer_fixture(context.organization.id, context.version.id, a, b)

      conn = editor_conn(context)
      {:ok, view, _html} = live(conn, blocks_path(version.id))

      view = open_checks(view)

      assert has_element?(view, "#checks-in-seat-version", "None left.")
      assert has_element?(view, "#checks-in-seat-version", "This version \u00b7 0")
      refute has_element?(view, "#checks-remove-unmatched")
      assert has_element?(view, "#remove-unmatched-dialog[data-open='false']")
    end
  end

  describe "removing from the Checks drawer" do
    setup :editor_scope

    test "the day-type question names k and deletes exactly the stale rows",
         %{version: version} = context do
      %{stay: stay, reboard: reboard, drifted: drifted, stale_a: stale_a, stale_b: stale_b} =
        in_seat_day(context)

      conn = editor_conn(context)
      {:ok, view, _html} = live(conn, blocks_path(version.id))

      view = open_checks(view)

      view |> element("#checks-remove-stale") |> render_click()

      assert has_element?(view, "#remove-stale-dialog", "Remove 3 in-seat records?")
      assert has_element?(view, "#remove-stale-dialog", "These records no longer match")
      assert has_element?(view, "#remove-stale-dialog", "Weekday blocks")
      assert has_element?(view, "#remove-stale-dialog", "Each deletion is audited")
      assert has_element?(view, "#remove-stale-dialog-confirm", "Remove 3 records")

      # Cancelling asks nothing and deletes nothing.
      view |> element("#remove-stale-dialog-cancel") |> render_click()

      assert has_element?(view, "#remove-stale-dialog[data-open='false']")
      assert Repo.get(Transfer, drifted.id)
      assert Repo.get(Transfer, stale_a.id)
      assert Repo.get(Transfer, stale_b.id)

      view |> element("#checks-remove-stale") |> render_click()
      html = view |> element("#remove-stale-dialog-confirm") |> render_click()

      assert html =~ "Removed 3 in-seat records."

      # Exactly {k} went; the conflicting pair needs a choice and stays.
      assert Repo.get(Transfer, drifted.id) == nil
      assert Repo.get(Transfer, stale_a.id) == nil
      assert Repo.get(Transfer, stale_b.id) == nil
      assert Repo.get(Transfer, stay.id)
      assert Repo.get(Transfer, reboard.id)

      # Both counts refresh from the reloaded day and the reloaded version read:
      # the no-block rows were the version's unmatched rows too.
      assert has_element?(view, "#checks-in-seat", "In-seat records that need review \u00b7 1")
      refute has_element?(view, "#checks-remove-stale")
      assert has_element?(view, "#checks-in-seat-version", "This version \u00b7 0")
      assert has_element?(view, "#checks-in-seat-version", "None left.")
    end

    test "the version question names m and deletes exactly the unmatched rows",
         %{version: version} = context do
      %{stay: stay, reboard: reboard, stale_a: stale_a, stale_b: stale_b} = in_seat_day(context)

      conn = editor_conn(context)
      {:ok, view, _html} = live(conn, blocks_path(version.id))

      view = open_checks(view)

      view |> element("#checks-remove-unmatched") |> render_click()

      assert has_element?(view, "#remove-unmatched-dialog", "Remove 2 in-seat records?")
      assert has_element?(view, "#remove-unmatched-dialog", "any block of this version")
      assert has_element?(view, "#remove-unmatched-dialog-confirm", "Remove 2 records")

      html = view |> element("#remove-unmatched-dialog-confirm") |> render_click()

      assert html =~ "Removed 2 in-seat records."
      assert Repo.get(Transfer, stale_a.id) == nil
      assert Repo.get(Transfer, stale_b.id) == nil
      assert Repo.get(Transfer, stay.id)
      assert Repo.get(Transfer, reboard.id)

      assert has_element?(view, "#checks-in-seat-version", "This version \u00b7 0")
      assert has_element?(view, "#checks-in-seat-version", "None left.")
      refute has_element?(view, "#checks-remove-unmatched")
      assert has_element?(view, "#remove-unmatched-dialog[data-open='false']")
    end

    test "a row changed since the drawer listed it refuses the whole batch",
         %{version: version} = context do
      %{drifted: drifted} = in_seat_day(context)

      conn = editor_conn(context)
      {:ok, view, _html} = live(conn, blocks_path(version.id))

      view = open_checks(view)

      view |> element("#checks-remove-stale") |> render_click()

      # Another editor touches the listed row after the drawer listed it, so the
      # stored `updated_at` no longer matches the confirmation's.
      later = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.add(60, :second)

      {1, _} =
        Repo.update_all(from(t in Transfer, where: t.id == ^drifted.id), set: [updated_at: later])

      html = view |> element("#remove-stale-dialog-confirm") |> render_click()

      assert html =~ "Records changed. Nothing was removed."

      # `remove_records/2` deletes nothing when any listed member is stale.
      assert Repo.get(Transfer, drifted.id)

      # The reload shows the reader the listing that is actually stored.
      assert has_element?(view, "#checks-in-seat", "In-seat records that need review \u00b7 4")
      assert has_element?(view, "#checks-remove-stale", "Remove 3 records that no longer match")
    end

    test "a viewer cannot remove: the permission flash answers and every row stays",
         %{version: version} = context do
      %{drifted: drifted, stale_a: stale_a, stale_b: stale_b} = in_seat_day(context)

      conn = editor_conn(context)
      {:ok, view, _html} = live(conn, blocks_path(version.id))

      view = open_checks(view)

      view |> element("#checks-remove-stale") |> render_click()
      assert has_element?(view, "#remove-stale-dialog[data-open='true']")

      # No viewer role exists; a revoked editor is a membership with no roles.
      membership = Accounts.get_user_org_membership(context.user.id, context.organization.id)
      {:ok, _membership} = Accounts.update_user_org_membership(membership, %{roles: []})

      html = view |> element("#remove-stale-dialog-confirm") |> render_click()

      assert html =~ "You don&#39;t have permission to change blocks in this version."
      assert Repo.get(Transfer, drifted.id)
      assert has_element?(view, "#checks-in-seat", "In-seat records that need review \u00b7 4")
      assert has_element?(view, "#remove-stale-dialog[data-open='false']")

      # The version-level question is refused the same way.
      view |> element("#checks-remove-unmatched") |> render_click()
      html = view |> element("#remove-unmatched-dialog-confirm") |> render_click()

      assert html =~ "You don&#39;t have permission to change blocks in this version."
      assert Repo.get(Transfer, stale_a.id)
      assert Repo.get(Transfer, stale_b.id)
    end
  end
end
