defmodule GtfsPlannerWeb.Gtfs.BlocksBlockActionsLiveTest do
  # EV-26: the block drawer's rename, merge and remove-all actions, observed
  # through the ordinary `/gtfs/:version/blocks` route on the production
  # `CatalogReadAdapter.Repo` and the scoped `Blocking` context, so every action
  # reaches the real `Gtfs.apply_block_change/4`. Rows are created inside the SQL
  # Sandbox transaction and rolled back; nothing here substitutes an adapter.
  #
  # The card's browser scenarios (the rename form, the split review and the merge
  # picker at 1440×1000) belong to `assets/e2e/blocks.spec.js`, which step 29 owns
  # with EV-28; this file writes the EV-26 cases.
  #
  # The focused gate command is deferred to branch review:
  # `mix test test/gtfs_planner_web/live/gtfs/blocks_block_actions_live_test.exs`.
  use GtfsPlannerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.BlockingFixtures
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.Trip
  alias GtfsPlanner.Repo

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
        route_long_name: "Riverside"
      })

    %{user: user, organization: organization, version: version, route: route}
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

  # Ten March weekdays: a dates-only calendar that shares its dates with the
  # weekday one, so the two derive a “Weekday” day type and a “School + Weekday”
  # one. Block 101 runs on the weekday service alone, so renaming it on “Weekday”
  # is a rename of that day type's own trips and leaves the school trips behind:
  # the split the review names on the other day type.
  defp school_dates do
    ~D[2026-03-01]
    |> Date.range(~D[2026-03-31])
    |> Enum.filter(&(Date.day_of_week(&1) in 1..5))
    |> Enum.take(10)
  end

  defp day_scope(context) do
    calendar(context, "WK", "Weekday")
    calendar(context, "SCH", "School", %{dates: school_dates()})

    wk1 = trip(context, %{trip_id: "wk1", block_id: "101", first: "05:00:00", last: "05:30:00"})
    wk2 = trip(context, %{trip_id: "wk2", block_id: "101", first: "06:00:00", last: "06:30:00"})

    z1 =
      trip(context, %{
        trip_id: "z1",
        block_id: "101",
        service_id: "SCH",
        first: "09:00:00",
        last: "10:00:00"
      })

    z2 =
      trip(context, %{
        trip_id: "z2",
        block_id: "101",
        service_id: "SCH",
        first: "10:15:00",
        last: "10:45:00"
      })

    in1 = trip(context, %{trip_id: "in1", block_id: "102", first: "07:00:00", last: "07:30:00"})
    in2 = trip(context, %{trip_id: "in2", block_id: "102", first: "08:00:00", last: "08:30:00"})
    out1 = trip(context, %{trip_id: "out1", block_id: "103", first: "10:00:00", last: "10:30:00"})
    out2 = trip(context, %{trip_id: "out2", block_id: "103", first: "11:00:00", last: "11:30:00"})

    %{wk1: wk1, wk2: wk2, z1: z1, z2: z2, in1: in1, in2: in2, out1: out1, out2: out2}
  end

  defp doc(view), do: view |> render() |> LazyHTML.from_fragment()

  defp attributes(view, selector, attribute) do
    view |> doc() |> LazyHTML.query(selector) |> LazyHTML.attribute(attribute)
  end

  defp merge_blocks(view), do: attributes(view, "[data-role='merge-option']", "data-block")

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

  # Every case enters through the ordinary router: log in, read the day-type key
  # off the page's own select, then follow the `day=`/`block=` deep link that
  # opens the block drawer on that day type.
  defp open_block_day(context, day_label, block_id) do
    conn = editor_conn(context)
    base = blocks_path(context.version.id)
    {:ok, page, _html} = live(conn, base)
    key = day_key(page, day_label)

    {:ok, view, _html} = live(conn, base <> "?day=#{key}&block=#{block_id}")
    %{view: view, conn: conn, base: base, key: key}
  end

  defp submit_rename(view, block_id) do
    view
    |> form("#block-rename-form", block_action: %{block_id: block_id})
    |> render_submit()
  end

  defp submit_merge(view, destination) do
    view
    |> form("#block-merge-form", block_action: %{destination: destination})
    |> render_submit()
  end

  defp confirm_review(view), do: view |> element("#block-review-confirm") |> render_click()

  defp persisted(trip), do: Repo.get!(Trip, trip.id)

  defp trip_logs(context, trip) do
    Gtfs.list_change_logs_for_entity(
      context.organization.id,
      context.version.id,
      "trip",
      trip.id
    )
  end

  describe "renaming a block from its drawer" do
    setup :editor_scope

    test "renames this day type's trips and reviews the split on the other one", context do
      %{wk1: wk1, wk2: wk2, z1: z1, z2: z2} = day_scope(context)

      %{view: view, base: base, key: key} = open_block_day(context, "Weekday", "101")
      school_key = day_key(view, "School")

      # The drawer's three actions are the reference's; the rename field starts on
      # the block's own ID.
      assert has_element?(view, "#block-drawer", "Block actions")
      assert has_element?(view, "#block-rename-form")
      assert has_element?(view, "#block-rename-id[value='101']")
      assert has_element?(view, "#block-rename-submit", "Rename block")
      assert has_element?(view, "#block-merge-form")
      assert has_element?(view, "#block-merge-submit", "Merge blocks")
      assert has_element?(view, "#block-remove-all", "Remove all trips")

      submit_rename(view, "201")

      # A rename always needs the review, and the review writes nothing.
      assert has_element?(view, "#block-review[data-open='true']")
      assert has_element?(view, "#block-review-confirm", "Rename block")
      assert has_element?(view, "#block-review-cancel", "Change selection")
      assert has_element?(view, "#block-review-changes-table", "wk1")
      assert has_element?(view, "#block-review-changes-table", "wk2")
      refute has_element?(view, "#block-review-changes-table", "z1")
      assert persisted(wk1).block_id == "101"
      assert persisted(wk2).block_id == "101"

      assert has_element?(
               view,
               "#review-effect-#{key}[data-selected='true']",
               "2 trip assignments change to block 201."
             )

      assert has_element?(
               view,
               "#review-effect-#{school_key}[data-selected='false']",
               "Also changes"
             )

      assert has_element?(
               view,
               "#review-effect-#{school_key}",
               "Block 101 splits: 2 trips stay on 101."
             )

      html = confirm_review(view)

      assert html =~ "Saved the block change."
      assert persisted(wk1).block_id == "201"
      assert persisted(wk2).block_id == "201"
      assert persisted(z1).block_id == "101"
      assert persisted(z2).block_id == "101"

      refute has_element?(view, "#block-review[data-open='true']")
      refute has_element?(view, "#block-drawer")
      assert_patch(view, base <> "?day=#{key}")

      # One audit entry per changed trip, in the Schedules shape (INV-4): both
      # logs name the whole command's changed trips and its one operation.
      changed = Enum.sort([wk1.id, wk2.id])

      assert [log] = trip_logs(context, wk1)
      assert log.changed_fields["before"]["block_id"] == "101"
      assert log.changed_fields["after"]["block_id"] == "201"
      assert log.changed_fields["affected_trip_ids"] == changed

      assert [other] = trip_logs(context, wk2)
      assert other.changed_fields["after"]["block_id"] == "201"
      assert other.changed_fields["affected_trip_ids"] == changed
      assert other.changed_fields["operation_id"] == log.changed_fields["operation_id"]
    end

    test "a taken ID shows its sentence under the field and keeps the input", context do
      %{wk1: wk1} = day_scope(context)

      %{view: view} = open_block_day(context, "Weekday", "101")

      submit_rename(view, "102")

      refute has_element?(view, "#block-review[data-open='true']")

      assert has_element?(
               view,
               "#block-rename-id-error",
               "Block 102 already runs on these dates. Choose another ID or merge."
             )

      # The reader's input is kept and the block still carries its own ID.
      assert attributes(view, "#block-rename-id", "value") == ["102"]
      assert attributes(view, "#block-rename-id", "aria-invalid") == ["true"]
      assert persisted(wk1).block_id == "101"
    end

    test "a blank and an over-long ID show the length sentence", context do
      day_scope(context)

      %{view: view} = open_block_day(context, "Weekday", "101")
      long = String.duplicate("a", 256)

      submit_rename(view, "")

      assert has_element?(
               view,
               "#block-rename-id-error",
               "Enter a block ID of 1 to 255 characters."
             )

      assert attributes(view, "#block-rename-id", "value") == [""]

      submit_rename(view, long)

      assert has_element?(
               view,
               "#block-rename-id-error",
               "Enter a block ID of 1 to 255 characters."
             )

      assert attributes(view, "#block-rename-id", "value") == [long]
    end

    test "an unchanged ID shows the different-ID sentence", context do
      day_scope(context)

      %{view: view} = open_block_day(context, "Weekday", "101")

      submit_rename(view, "101")

      assert has_element?(view, "#block-rename-id-error", "Enter a different block ID.")
      refute has_element?(view, "#block-review[data-open='true']")
    end
  end

  describe "merging a block from its drawer" do
    setup :editor_scope

    test "reviews, then moves this block's trips into the chosen block", context do
      %{in1: in1, in2: in2, wk1: wk1} = day_scope(context)

      %{view: view, base: base, key: key} = open_block_day(context, "Weekday", "102")

      # The picker offers the day type's other blocks only: never the block being
      # merged, and neither “New block” nor “No block”.
      assert merge_blocks(view) == ["101", "103"]
      refute has_element?(view, "[data-role='merge-option'][data-block='102']")
      refute has_element?(view, "#block-merge-form", "New block")
      refute has_element?(view, "[data-role='merge-option'][data-block='none']")

      submit_merge(view, "101")

      assert has_element?(view, "#block-review[data-open='true']")
      assert has_element?(view, "#block-review-confirm", "Merge blocks")
      assert has_element?(view, "#block-review-changes-table", "in1")
      assert has_element?(view, "#block-review-changes-table", "in2")
      assert persisted(in1).block_id == "102"
      assert persisted(in2).block_id == "102"

      html = confirm_review(view)

      assert html =~ "Saved the block change."
      assert persisted(in1).block_id == "101"
      assert persisted(in2).block_id == "101"
      assert persisted(wk1).block_id == "101"

      refute has_element?(view, "#block-review[data-open='true']")
      refute has_element?(view, "#block-drawer")
      assert_patch(view, base <> "?day=#{key}")
    end

    test "a merge with no destination chosen refuses without a review", context do
      day_scope(context)

      %{view: view} = open_block_day(context, "Weekday", "102")

      html = view |> form("#block-merge-form") |> render_submit()

      refute has_element?(view, "#block-review[data-open='true']")
      assert has_element?(view, "#block-merge-error", "Choose a destination block.")
      refute html =~ "Saved the block change."
    end
  end

  describe "removing every trip from a block" do
    setup :editor_scope

    test "reviews, then moves this day type's trips to the pool", context do
      %{out1: out1, out2: out2} = day_scope(context)

      %{view: view, key: key} = open_block_day(context, "Weekday", "103")

      view |> element("#block-remove-all") |> render_click()

      assert has_element?(view, "#block-review[data-open='true']")
      assert has_element?(view, "#block-review-confirm", "Remove 2 trips")
      assert has_element?(view, "#block-review-changes-table", "out1")
      assert persisted(out1).block_id == "103"
      assert persisted(out2).block_id == "103"

      html = confirm_review(view)

      assert html =~ "Removed 2 trips from block 103."
      assert persisted(out1).block_id == nil
      assert persisted(out2).block_id == nil

      # The drawer closes with the block parameter, and both trips are in the
      # day type's pool now.
      refute has_element?(view, "#block-drawer")

      path = assert_patch(view)
      refute path =~ "block="
      refute path =~ "trip="
      assert path =~ "day=#{key}"

      assert {:ok, day} =
               Gtfs.load_blocking_day(context.organization.id, context.version.id, nil)

      assert Enum.sort(Enum.map(day.pool, & &1.trip_id)) == ["out1", "out2"]

      view |> element("#panel-pool") |> render_click()
      assert has_element?(view, "#blocks-pool-table", "out1")
      assert has_element?(view, "#blocks-pool-table", "out2")

      assert [log] = trip_logs(context, out1)
      assert log.changed_fields["before"]["block_id"] == "103"
      assert log.changed_fields["after"]["block_id"] == nil
    end

    test "a block of one trip saves directly, as the confirmation rule allows", context do
      day_scope(context)

      alone =
        trip(context, %{trip_id: "alone", block_id: "104", first: "12:00:00", last: "12:30:00"})

      %{view: view} = open_block_day(context, "Weekday", "104")

      html = view |> element("#block-remove-all") |> render_click()

      refute has_element?(view, "#block-review[data-open='true']")
      assert html =~ "Removed 1 trip from block 104."
      assert persisted(alone).block_id == nil
    end
  end
end
