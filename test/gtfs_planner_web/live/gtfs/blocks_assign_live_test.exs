defmodule GtfsPlannerWeb.Gtfs.BlocksAssignLiveTest do
  # Assigning one trip from its drawer through the review dialog, observed
  # through the ordinary `/gtfs/:version/blocks` route on the production
  # `CatalogReadAdapter.Repo` and the scoped `Blocking` context, so every case
  # reaches the real `Gtfs.apply_block_change/4`. Rows are created inside the SQL
  # Sandbox transaction and rolled back; only the `:busy` case swaps
  # `:reviewed_apply_transaction` for the Mox mock and restores it in `on_exit`.
  use GtfsPlannerWeb.ConnCase, async: false

  import Ecto.Query
  import Mox
  import Phoenix.LiveViewTest
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.BlockingFixtures
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.ReviewedApplyTransactionMock
  alias GtfsPlanner.Gtfs.Trip
  alias GtfsPlanner.Repo

  defp editor_scope(_context) do
    organization = organization_fixture()
    user = user_fixture()

    {:ok, membership} =
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

    %{
      user: user,
      organization: organization,
      version: version,
      route: route,
      membership: membership
    }
  end

  defp blocks_path(version_id), do: "/gtfs/#{version_id}/blocks"

  defp editor_conn(context),
    do: log_in_user(context.conn, context.user, organization: context.organization)

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

  # `w` runs on every weekday and sits alone in block 101, so 101 exists on both
  # day types; `z` runs only on the school dates and overlaps `x` there. Moving the
  # unassigned `x` into 101 is safe on the viewed “Weekday” day type and adds an
  # overlap on “School + Weekday”.
  defp cross_day_scope(context) do
    calendar(context, "WK", "Weekday")
    calendar(context, "SCH", "School", %{dates: school_dates()})

    w = trip(context, %{trip_id: "w", block_id: "101", first: "05:00:00", last: "05:30:00"})

    z =
      trip(context, %{
        trip_id: "z",
        block_id: "101",
        service_id: "SCH",
        first: "08:30:00",
        last: "09:30:00"
      })

    x = trip(context, %{trip_id: "x", first: "08:00:00", last: "09:00:00"})

    %{w: w, z: z, x: x}
  end

  defp doc(view), do: view |> render() |> LazyHTML.from_fragment()

  defp element_count(view, selector) do
    view |> doc() |> LazyHTML.query(selector) |> Enum.count()
  end

  defp texts(view, selector) do
    view
    |> doc()
    |> LazyHTML.query(selector)
    |> Enum.map(&(LazyHTML.text(&1) |> String.trim()))
  end

  defp attributes(view, selector, attribute) do
    view |> doc() |> LazyHTML.query(selector) |> LazyHTML.attribute(attribute)
  end

  defp option_blocks(view), do: attributes(view, "[data-role='destination-option']", "data-block")

  defp day_options(view) do
    view
    |> doc()
    |> LazyHTML.query("#blocks-day option")
    |> Enum.map(fn option ->
      {LazyHTML.attribute(option, "value") |> List.first(),
       LazyHTML.text(option) |> String.trim()}
    end)
  end

  defp day_key(view, label) do
    {key, _label} =
      Enum.find(day_options(view), fn {_key, text} -> String.starts_with?(text, label) end)

    key
  end

  defp dates_matching(fun) do
    ~D[2026-01-01] |> Date.range(~D[2026-12-31]) |> Enum.count(fun)
  end

  defp weekday_dates, do: dates_matching(&(Date.day_of_week(&1) in 1..5))

  # Ten March weekdays: a dates-only calendar that shares its dates with the
  # weekday one, so the two derive a “School + Weekday” day type beside the plain
  # “Weekday” one.
  defp school_dates do
    ~D[2026-03-01]
    |> Date.range(~D[2026-03-31])
    |> Enum.filter(&(Date.day_of_week(&1) in 1..5))
    |> Enum.take(10)
  end

  # Every case enters through the ordinary router: log in, open the page, read the
  # day-type key off its own select and follow the day-type deep link, so nothing
  # here constructs the LiveView's internal state.
  defp open_day(context, day_label, trip_id \\ nil) do
    conn = editor_conn(context)
    base = blocks_path(context.version.id)
    {:ok, page, _html} = live(conn, base)
    key = day_key(page, day_label)

    params =
      [{"day", key}, {"trip", trip_id}]
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> URI.encode_query()

    {:ok, view, _html} = live(conn, base <> "?" <> params)
    %{view: view, conn: conn, base: base, key: key}
  end

  defp open_assign(view, trip_id) do
    assert has_element?(view, "#trip-drawer", "Trip #{trip_id}")
    view |> element("#trip-change-assignment") |> render_click()
  end

  defp submit_assign(view, destination) do
    view
    |> form("#assign-form", assign: %{destination: destination})
    |> render_submit()
  end

  defp confirm_review(view), do: view |> element("#block-review-confirm") |> render_click()

  defp trip_logs(context, trip) do
    Gtfs.list_change_logs_for_entity(
      context.organization.id,
      context.version.id,
      "trip",
      trip.id
    )
  end

  defp persisted(trip), do: Repo.get!(Trip, trip.id)

  defp use_reviewed_apply_transaction_mock do
    previous = Application.fetch_env(:gtfs_planner, :reviewed_apply_transaction)

    Application.put_env(:gtfs_planner, :reviewed_apply_transaction, ReviewedApplyTransactionMock)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:gtfs_planner, :reviewed_apply_transaction, value)
        :error -> Application.delete_env(:gtfs_planner, :reviewed_apply_transaction)
      end
    end)
  end

  defp clock(secs),
    do: "#{pad(div(secs, 3_600))}:#{pad(div(rem(secs, 3_600), 60))}:00"

  defp pad(value), do: String.pad_leading(Integer.to_string(value), 2, "0")

  describe "a safe single-trip assign" do
    setup :editor_scope

    test "saves directly, updates the row, flashes and shows the trip's page", context do
      calendar(context, "WK", "Weekday")

      other =
        trip(context, %{trip_id: "other", block_id: "101", first: "05:00:00", last: "05:30:00"})

      x = trip(context, %{trip_id: "x", first: "08:00:00", last: "09:00:00"})

      %{view: view, base: base, key: key} = open_day(context, "Weekday", "x")

      assert has_element?(view, "#trip-drawer", "Trip x")

      open_assign(view, "x")

      assert has_element?(view, "#assign-form")
      assert has_element?(view, "#destination-search")
      assert has_element?(view, "#assign-form", "1 trip · applies on #{weekday_dates()} days")
      assert has_element?(view, "#destination-new")
      refute has_element?(view, "[data-role='destination-option'][data-block='none']")

      # A new block adds no problem anywhere, so the command applies without a
      # review and resolves the smallest unused ID.
      html = submit_assign(view, "new")

      refute has_element?(view, "#block-review[data-open='true']")
      assert html =~ "Assigned 1 trip to block 1."
      assert persisted(x).block_id == "1"
      assert persisted(other).block_id == "101"
      refute has_element?(view, "#assign-form")
      refute has_element?(view, "#trip-drawer")

      # The page holding the changed trip is shown: its new block row is on page 1
      # and the trip deep link is gone from the URL.
      assert_patch(view, base <> "?day=#{key}")
      assert has_element?(view, "[data-block='1']")

      assert [log] = trip_logs(context, x)
      assert log.entity_type == "trip"
      assert log.action == "updated"
      assert log.changed_fields["before"]["block_id"] == nil
      assert log.changed_fields["after"]["block_id"] == "1"
      assert log.changed_fields["affected_trip_ids"] == [x.id]
      assert is_binary(log.changed_fields["operation_id"])
    end

    test "“Remove from block” on one blocked trip saves directly", context do
      calendar(context, "WK", "Weekday")

      alone =
        trip(context, %{trip_id: "alone", block_id: "201", first: "05:00:00", last: "05:30:00"})

      %{view: view, base: base, key: key} = open_day(context, "Weekday", "alone")

      assert has_element?(view, "#trip-unassign", "Remove from block")

      html = view |> element("#trip-unassign") |> render_click()

      refute has_element?(view, "#block-review[data-open='true']")
      assert html =~ "Removed 1 trip from block 201."
      assert persisted(alone).block_id == nil

      # The trip is unassigned now, so the page that holds it is the pool.
      assert_patch(view, base <> "?day=#{key}&panel=pool")
      assert has_element?(view, "#blocks-pool-table", "alone")

      assert [log] = trip_logs(context, alone)
      assert log.changed_fields["before"]["block_id"] == "201"
      assert log.changed_fields["after"]["block_id"] == nil
    end
  end

  describe "an assign that adds an overlap only on another day type" do
    setup :editor_scope

    test "opens #block-review with an “Also changes” effect and the added problem",
         context do
      %{w: w, x: x} = cross_day_scope(context)

      %{view: view, key: key} = open_day(context, "Weekday", "x")
      school_key = day_key(view, "School")

      open_assign(view, "x")
      submit_assign(view, "101")

      assert has_element?(view, "#block-review[data-open='true']")
      assert has_element?(view, "#block-review", "Assignment changes")
      assert has_element?(view, "#block-review", "Preview · not saved")

      # The viewed service day is this service day and adds no problem; the other one
      # is “Also changes” and lists the overlap the assign introduces there.
      assert has_element?(
               view,
               "#review-effect-#{key}[data-selected='true']",
               "This service day · Weekday · #{weekday_dates() - length(school_dates())} days"
             )

      assert has_element?(
               view,
               "#review-effect-#{key}",
               "No new timing or transfer problems on these days."
             )

      assert has_element?(
               view,
               "#review-effect-#{school_key}[data-selected='false']",
               "Also changes · School + Weekday · #{length(school_dates())} days"
             )

      assert has_element?(
               view,
               "#review-effect-#{school_key}",
               "1 trip assignment changes to block 101."
             )

      assert has_element?(
               view,
               "#review-effect-#{school_key} [data-role='review-added']",
               "Overlap"
             )

      assert has_element?(view, "#block-review-changes-table", "x")
      assert has_element?(view, "#block-review-changes-table", "GDX") == false

      # Confirming persists the change and writes the change log.
      html = confirm_review(view)

      assert html =~ "Assigned 1 trip to block 101."
      assert persisted(x).block_id == "101"
      assert persisted(w).block_id == "101"
      refute has_element?(view, "#block-review[data-open='true']")

      assert [log] = trip_logs(context, x)
      assert log.changed_fields["before"]["block_id"] == nil
      assert log.changed_fields["after"]["block_id"] == "101"
      assert is_binary(log.changed_fields["operation_id"])
    end

    test "the confirm button repeats the verb and its object", context do
      %{x: _x} = cross_day_scope(context)

      %{view: view} = open_day(context, "Weekday", "x")

      open_assign(view, "x")
      submit_assign(view, "101")

      assert has_element?(view, "#block-review-confirm", "Assign 1 trip")
      assert has_element?(view, "#block-review-cancel", "Change block")
    end

    test "“Change block” closes the review and restores the form with the target",
         context do
      %{x: x} = cross_day_scope(context)

      %{view: view} = open_day(context, "Weekday", "x")

      open_assign(view, "x")
      submit_assign(view, "101")

      assert has_element?(view, "#block-review[data-open='true']")

      view |> element("#block-review-cancel") |> render_click()

      refute has_element?(view, "#block-review[data-open='true']")
      refute has_element?(view, "#block-review-stale")
      assert has_element?(view, "#assign-form")

      assert has_element?(
               view,
               "[data-role='destination-option'][data-block='101'] input[checked]"
             )

      # Opening and closing the review writes nothing.
      assert persisted(x).block_id == nil
      assert trip_logs(context, x) == []
    end

    test "a touched trip changed after the review shows the refreshed review and writes nothing",
         context do
      %{w: w, x: x} = cross_day_scope(context)

      %{view: view} = open_day(context, "Weekday", "x")

      open_assign(view, "x")
      submit_assign(view, "101")

      assert has_element?(view, "#block-review[data-open='true']")

      # A second writer touches a trip of the target block between the review and
      # the confirmation: its `updated_at` is part of the fingerprint.
      bumped = DateTime.add(DateTime.utc_now(), 60, :second)

      {1, _rows} =
        Repo.update_all(from(t in Trip, where: t.id == ^w.id), set: [updated_at: bumped])

      confirm_review(view)

      assert has_element?(
               view,
               "#block-review-stale",
               "Trips changed since you reviewed."
             )

      assert has_element?(view, "#block-review[data-open='true']")
      assert persisted(x).block_id == nil
      assert trip_logs(context, x) == []
      assert DateTime.compare(persisted(w).updated_at, bumped) == :eq
    end

    test "a busy apply keeps the form and target and shows its sentence", context do
      %{x: x} = cross_day_scope(context)

      %{view: view} = open_day(context, "Weekday", "x")

      open_assign(view, "x")
      submit_assign(view, "101")

      assert has_element?(view, "#block-review[data-open='true']")

      # `run_write/2` wraps the entire command, so the submit that *opens* the
      # review runs the real transaction too. The mock is installed only here, so
      # the one permitted call is the confirmation below.
      set_mox_global()
      use_reviewed_apply_transaction_mock()

      expect(ReviewedApplyTransactionMock, :run, fn _transaction -> {:error, :busy} end)

      confirm_review(view)

      assert has_element?(
               view,
               "#block-review-error",
               "Another change is being saved. Try again in a moment."
             )

      # The review, the form and the chosen target are all still there.
      assert has_element?(view, "#block-review[data-open='true']")
      assert has_element?(view, "#block-review-confirm", "Assign 1 trip")

      assert has_element?(
               view,
               "[data-role='destination-option'][data-block='101'] input[checked]"
             )

      assert persisted(x).block_id == nil
      assert trip_logs(context, x) == []
    end
  end

  describe "the destination picker" do
    setup :editor_scope

    test "“New block” shows the resolved ID in the review's Proposed block column", context do
      calendar(context, "WK", "Weekday")

      p = trip(context, %{trip_id: "p", block_id: "101", first: "08:00:00", last: "09:00:00"})
      y = trip(context, %{trip_id: "y", block_id: "101", first: "10:00:00", last: "11:00:00"})

      # A matching in-seat record turns the move out of 101 into a stale record, so
      # the new-block assign needs confirmation and the review names the resolved ID.
      in_seat_transfer_fixture(context.organization.id, context.version.id, p, y)

      %{view: view} = open_day(context, "Weekday", "p")

      open_assign(view, "p")
      submit_assign(view, "new")

      assert has_element?(view, "#block-review[data-open='true']")
      assert texts(view, "[data-role='review-proposed']") == ["1"]
      assert has_element?(view, "#block-review", "Stay-on-board mismatch")

      confirm_review(view)

      assert persisted(p).block_id == "1"

      assert [log] = trip_logs(context, p)
      assert log.changed_fields["before"]["block_id"] == "101"
      assert log.changed_fields["after"]["block_id"] == "1"
    end

    test "an exact match leads the results and the list is capped at 25", context do
      calendar(context, "WK", "Weekday")

      for index <- 1..30 do
        block = "B" <> String.pad_leading(Integer.to_string(index), 2, "0")
        start = 1 * 3_600 + index * 60

        trip(context, %{
          trip_id: "filler_#{index}",
          block_id: block,
          first: clock(start),
          last: clock(start + 600)
        })
      end

      trip(context, %{trip_id: "ab1", block_id: "AB1", first: "20:00:00", last: "20:10:00"})
      trip(context, %{trip_id: "b1", block_id: "B1", first: "21:00:00", last: "21:10:00"})
      trip(context, %{trip_id: "x", first: "08:00:00", last: "09:00:00"})

      %{view: view} = open_day(context, "Weekday", "x")

      open_assign(view, "x")

      # 32 blocks match an empty search; the picker shows 25 and says so.
      assert element_count(view, "[data-role='destination-option']") == 25

      assert has_element?(
               view,
               "#destination-summary",
               "25 of 32 matching blocks · refine your search"
             )

      view
      |> form("#assign-form", assign: %{search: "B1"})
      |> render_change()

      blocks = option_blocks(view)
      assert "B1" in blocks
      assert "AB1" in blocks
      assert Enum.find_index(blocks, &(&1 == "B1")) < Enum.find_index(blocks, &(&1 == "AB1"))
      assert has_element?(view, "#destination-summary", "matching blocks")
    end

    test "the pool row's “Assign trip” opens the drawer and the form", context do
      calendar(context, "WK", "Weekday")
      trip(context, %{trip_id: "x", first: "08:00:00", last: "09:00:00"})

      %{view: view, base: base, key: key} = open_day(context, "Weekday")

      view |> element("#panel-pool") |> render_click()
      view |> element("[data-role='assign-trip']") |> render_click()

      assert_patch(view, base <> "?day=#{key}&panel=pool&trip=x")
      assert has_element?(view, "#trip-drawer", "Trip x")
      assert has_element?(view, "#assign-form")
    end
  end

  describe "editor authority" do
    setup :editor_scope

    test "a revoked editor role writes nothing and shows the permission message",
         %{membership: membership} = context do
      calendar(context, "WK", "Weekday")
      x = trip(context, %{trip_id: "x", first: "08:00:00", last: "09:00:00"})

      %{view: view} = open_day(context, "Weekday", "x")

      open_assign(view, "x")

      # No viewer role exists; a revoked editor is a membership with no roles.
      {:ok, _membership} = Accounts.update_user_org_membership(membership, %{roles: []})

      html = submit_assign(view, "new")

      assert html =~ "You don&#39;t have permission to change blocks in this version."
      assert persisted(x).block_id == nil
      assert trip_logs(context, x) == []
      refute has_element?(view, "#block-review[data-open='true']")
    end
  end

  describe "the ordinary entry" do
    setup :editor_scope

    test "a trip= deep link reaches the real Gtfs.apply_block_change/4 and writes through it",
         context do
      calendar(context, "WK", "Weekday")

      other =
        trip(context, %{trip_id: "other", block_id: "101", first: "05:00:00", last: "05:30:00"})

      x = trip(context, %{trip_id: "x", first: "08:00:00", last: "09:00:00"})

      conn = editor_conn(context)
      base = blocks_path(context.version.id)

      {:ok, view, _html} = live(conn, base <> "?trip=x")

      assert has_element?(view, "#trip-drawer", "Trip x")

      open_assign(view, "x")
      html = submit_assign(view, "101")

      assert html =~ "Assigned 1 trip to block 101."
      assert persisted(x).block_id == "101"
      assert persisted(other).block_id == "101"

      assert [log] = trip_logs(context, x)
      assert log.action == "updated"
      assert log.changed_fields["affected_trip_ids"] == [x.id]

      # The same persisted change is what the page's own read path returns.
      assert {:ok, day} = Gtfs.load_blocking_day(context.organization.id, context.version.id, nil)

      assert Enum.any?(day.blocks, fn block ->
               block.summary.block_id == "101" and Enum.any?(block.trips, &(&1.id == x.id))
             end)
    end
  end
end
