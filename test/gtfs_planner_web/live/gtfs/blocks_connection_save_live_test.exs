defmodule GtfsPlannerWeb.Gtfs.BlocksConnectionSaveLiveTest do
  # The connection drawer's save: the one guarded write the drawer owns, the
  # persistent result it leaves behind, the guarded Undo on top of that, and the
  # answers that keep the drawer and the editor's choice.
  #
  # Every case is observed through the ordinary `/gtfs/:version/blocks` route and
  # the `gap=` deep link, on the production `CatalogReadAdapter.Repo` and the
  # scoped `Blocking` context, so the drawer calls the same `Gtfs
  # .set_in_seat_connection/5` the rest of the package does (CR-2, CR-8). Rows are
  # created inside the SQL Sandbox transaction and rolled back; nothing here
  # substitutes an adapter or a context.
  use GtfsPlannerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.AdvancedBlockingFixtures
  import GtfsPlanner.BlockingFixtures
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Gtfs.Transfer
  alias GtfsPlanner.Repo

  import Ecto.Query

  @permission_message "You don&#39;t have permission to change blocks in this version."

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
      twelve: twelve,
      twenty_four: twenty_four
    }
  end

  defp blocks_path(version_id), do: "/gtfs/#{version_id}/blocks"

  defp editor_conn(context) do
    log_in_user(context.conn, context.user, organization: context.organization)
  end

  defp coord(value), do: Decimal.new(value)

  defp trip(context, attrs) do
    attrs = Map.new(attrs)
    route_id = Map.get(attrs, :route, context.twelve.route_id)
    {first, attrs} = Map.pop(attrs, :first, "06:00:00")
    {last, attrs} = Map.pop(attrs, :last, "07:00:00")

    blocked_trip_fixture(
      context.organization.id,
      context.version.id,
      route_id,
      attrs
      |> Map.delete(:route)
      |> Map.put_new(:service_id, "W")
      |> Map.put_new(:trip_id, "trip_#{System.unique_integer([:positive])}")
      |> Map.put(:first_arrival, first)
      |> Map.put(:last_arrival, last)
    )
  end

  defp gap_url(base, from_trip, to_trip, extra \\ []) do
    base <> "?" <> URI.encode_query([{"gap", "#{from_trip.id}|#{to_trip.id}"}] ++ extra)
  end

  defp main_stop(context, suffix) do
    stop_with_coordinates_fixture(context.organization.id, context.version.id, %{
      stop_id: "SAVE_MAIN_#{suffix}_#{System.unique_integer([:positive])}",
      stop_name: "Main St",
      stop_lat: coord("40.0200"),
      stop_lon: coord("-74.0000")
    })
  end

  # A same-block, same-stop weekday pair, which is the shape R1 allows a record for.
  defp same_stop_pair(context), do: same_stop_pair(context, "PAIR", "101")

  defp same_stop_pair(context, suffix), do: same_stop_pair(context, suffix, "101")

  defp same_stop_pair(context, suffix, block_id) do
    main = main_stop(context, suffix)

    a =
      trip(context, %{
        trip_id: "a_#{suffix}",
        block_id: block_id,
        first_stop: main.stop_id,
        last_stop: main.stop_id,
        first: "06:00:00",
        last: "07:00:00"
      })

    b =
      trip(context, %{
        route: context.twenty_four.route_id,
        trip_id: "b_#{suffix}",
        block_id: block_id,
        first_stop: main.stop_id,
        last_stop: main.stop_id,
        first: "07:10:00",
        last: "08:10:00"
      })

    {a, b, main}
  end

  defp choose(view, choice) do
    view
    |> element("#connection-form")
    |> render_change(%{
      "connection" => %{"choice" => to_string(choice)},
      "_target" => ["connection-choice-#{choice_id(choice)}"]
    })
  end

  defp choice_id(:not_stated), do: "not-stated"
  defp choice_id(:stay_on_board), do: "stay"
  defp choice_id(:must_reboard), do: "reboard"

  defp stored_transfers(context, a, b) do
    Transfer
    |> where([t], t.gtfs_version_id == ^context.version.id)
    |> where([t], t.from_trip_id == ^a.trip_id and t.to_trip_id == ^b.trip_id)
    |> where([t], t.transfer_type in [4, 5])
    |> Repo.all()
  end

  defp gap_setting(view, a, b) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("[data-role='blocks-gap'][data-from='#{a.id}'][data-to='#{b.id}']")
    |> Enum.map(&(LazyHTML.attribute(&1, "data-setting") |> List.first()))
  end

  describe "a successful save" do
    test "writes the row, closes the drawer and leaves a saved result with Undo", context do
      {a, b, _main} = same_stop_pair(context)

      {:ok, view, _html} =
        live(editor_conn(context), gap_url(blocks_path(context.version.id), a, b))

      choose(view, :stay_on_board)

      view |> element("#connection-save") |> render_click()
      assert render_async(view)

      # R2: one row, type 4, both routes nil and no minimum time.
      assert [transfer] = stored_transfers(context, a, b)
      assert transfer.transfer_type == 4
      assert transfer.from_route_id == nil
      assert transfer.to_route_id == nil

      # AC-15: the drawer closes and the URL stops naming the pair.
      refute has_element?(view, "#gap-drawer")

      # R10: the result persists, names what was written and offers Undo.
      assert has_element?(view, "[data-role='connection-result']", "Saved: riders stay on board")
      assert has_element?(view, "#connection-undo", "Undo")
      refute has_element?(view, "#connection-result-open")

      # FH-14/PM-12: the timeline's marker is the saved pair's own setting.
      assert gap_setting(view, a, b) == ["stay"]
    end

    test "the result stays until it is dismissed", context do
      {a, b, _main} = same_stop_pair(context)

      {:ok, view, _html} =
        live(editor_conn(context), gap_url(blocks_path(context.version.id), a, b))

      choose(view, :stay_on_board)
      view |> element("#connection-save") |> render_click()
      assert render_async(view)

      # R10: a later render leaves it alone; only the reader dismisses it.
      render(view)
      assert has_element?(view, "[data-role='connection-result']", "Saved:")

      view |> element("#connection-dismiss") |> render_click()
      refute has_element?(view, "[data-role='connection-result']")
    end

    test "choosing Not stated from a saved record deletes the row", context do
      {a, b, _main} = same_stop_pair(context)

      in_seat_transfer_fixture(context.organization.id, context.version.id, a, b)

      {:ok, view, _html} =
        live(editor_conn(context), gap_url(blocks_path(context.version.id), a, b))

      assert has_element?(view, "#connection-choice-stay[checked]")

      choose(view, :not_stated)
      view |> element("#connection-save") |> render_click()
      assert render_async(view)

      assert stored_transfers(context, a, b) == []
      assert has_element?(view, "[data-role='connection-result']", "Saved: not stated")
    end
  end

  describe "Undo" do
    test "restores Not stated from a stay save and writes nothing further", context do
      {a, b, _main} = same_stop_pair(context)

      {:ok, view, _html} =
        live(editor_conn(context), gap_url(blocks_path(context.version.id), a, b))

      choose(view, :stay_on_board)
      view |> element("#connection-save") |> render_click()
      assert render_async(view)
      assert [_transfer] = stored_transfers(context, a, b)

      view |> element("#connection-undo") |> render_click()

      assert has_element?(view, "[data-role='connection-result']", "Restored: not stated")
      refute has_element?(view, "#connection-undo")
      assert stored_transfers(context, a, b) == []
      assert gap_setting(view, a, b) == ["none"]
    end

    test "restores the previous setting from a replacement", context do
      {a, b, _main} = same_stop_pair(context)

      in_seat_transfer_fixture(context.organization.id, context.version.id, a, b)

      {:ok, view, _html} =
        live(editor_conn(context), gap_url(blocks_path(context.version.id), a, b))

      choose(view, :must_reboard)
      view |> element("#connection-save") |> render_click()
      assert render_async(view)
      assert [transfer] = stored_transfers(context, a, b)
      assert transfer.transfer_type == 5

      view |> element("#connection-undo") |> render_click()

      assert has_element?(
               view,
               "[data-role='connection-result']",
               "Restored: riders stay on board"
             )

      assert [transfer] = stored_transfers(context, a, b)
      assert transfer.transfer_type == 4
    end

    test "a stale undo is refused with the guarded result and writes nothing", context do
      {a, b, main} = same_stop_pair(context)

      {:ok, view, _html} =
        live(editor_conn(context), gap_url(blocks_path(context.version.id), a, b))

      choose(view, :stay_on_board)
      view |> element("#connection-save") |> render_click()
      assert render_async(view)

      # Someone else writes between the save and the Undo, so the guarded write's
      # `expected` — the row the save left — no longer matches (R9, INV-4).
      transfer_fixture(context.organization.id, context.version.id, %{
        transfer_type: 5,
        from_trip_id: a.trip_id,
        to_trip_id: b.trip_id,
        from_stop_id: nil,
        to_stop_id: nil
      })

      view |> element("#connection-undo") |> render_click()

      assert has_element?(
               view,
               "[data-role='connection-result']",
               "Couldn't undo: the connection changed after your save."
             )

      refute has_element?(view, "#connection-undo")
      assert has_element?(view, "#connection-result-open", "Open connection")

      # Both rows are untouched: the refused write deleted neither the row the
      # save made nor the other editor's.
      assert [_saved, other] = stored_transfers(context, a, b)
      assert other.transfer_type == 5
      assert other.from_stop_id == nil

      # The review link lands on the pair that changed.
      href =
        view
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("#connection-result-open")
        |> Enum.map(&(LazyHTML.attribute(&1, "href") |> List.first()))
        |> List.first()

      assert URI.decode(href) =~ "gap=#{a.id}|#{b.id}"
      assert main.stop_id
    end

    test "replacing two disagreeing records offers no Undo", context do
      {a, b, main} = same_stop_pair(context, "CONFLICT")

      transfer_fixture(context.organization.id, context.version.id, %{
        transfer_type: 4,
        from_trip_id: a.trip_id,
        to_trip_id: b.trip_id,
        from_stop_id: main.stop_id,
        to_stop_id: main.stop_id
      })

      transfer_fixture(context.organization.id, context.version.id, %{
        transfer_type: 5,
        from_trip_id: a.trip_id,
        to_trip_id: b.trip_id,
        from_stop_id: nil,
        to_stop_id: nil
      })

      {:ok, view, _html} =
        live(editor_conn(context), gap_url(blocks_path(context.version.id), a, b))

      choose(view, :stay_on_board)
      view |> element("#connection-save") |> render_click()
      assert render_async(view)

      assert has_element?(view, "[data-role='connection-result']", "Saved:")
      refute has_element?(view, "#connection-undo")
      assert [transfer] = stored_transfers(context, a, b)
      assert transfer.transfer_type == 4
    end
  end

  describe "the answers that keep the drawer" do
    test "a stale save keeps the drawer and the choice and explains itself", context do
      {a, b, _main} = same_stop_pair(context, "STALE")

      in_seat_transfer_fixture(context.organization.id, context.version.id, a, b)

      {:ok, view, _html} =
        live(editor_conn(context), gap_url(blocks_path(context.version.id), a, b))

      # The drawer resolves the pair's one type 4 record as the saved setting and
      # offers the three options from there.
      choose(view, :must_reboard)

      # Someone else replaces the record after the drawer read it, so the guarded
      # write's `expected` no longer matches and nothing is written (R4, INV-4).
      context
      |> stored_transfers(a, b)
      |> Enum.each(&Repo.delete!/1)

      transfer_fixture(context.organization.id, context.version.id, %{
        transfer_type: 5,
        from_trip_id: a.trip_id,
        to_trip_id: b.trip_id,
        from_stop_id: nil,
        to_stop_id: nil
      })

      view |> element("#connection-save") |> render_click()
      assert render_async(view)

      # The drawer stays open with the choice still checked and says nothing was
      # written (AC-15). The other editor's row is untouched.
      assert has_element?(view, "#gap-drawer")
      assert has_element?(view, "[data-role='connection-save-error']", "Nothing was saved.")
      assert has_element?(view, "#connection-choice-reboard[checked]")
      assert [transfer] = stored_transfers(context, a, b)
      assert transfer.transfer_type == 5
    end

    test "a revoked editor is refused the write and nothing is stored", context do
      {a, b, _main} = same_stop_pair(context, "REVOKED")

      {:ok, view, _html} =
        live(editor_conn(context), gap_url(blocks_path(context.version.id), a, b))

      choose(view, :stay_on_board)

      # No viewer role exists; a revoked editor is a membership with no roles.
      membership = Accounts.get_user_org_membership(context.user.id, context.organization.id)
      {:ok, _membership} = Accounts.update_user_org_membership(membership, %{roles: []})

      html = view |> element("#connection-save") |> render_click()

      assert html =~ @permission_message
      assert stored_transfers(context, a, b) == []
      # The drawer is still open with its choice: the refusal wrote nothing and
      # took nothing away.
      assert has_element?(view, "#gap-drawer")
    end

    test "a crafted save naming a foreign trip writes nothing", context do
      {a, b, _main} = same_stop_pair(context, "CRAFTED")
      {foreign_a, foreign_b, _foreign_main} = same_stop_pair(context, "OTHER", "202")

      {:ok, view, _html} =
        live(editor_conn(context), gap_url(blocks_path(context.version.id), a, b))

      choose(view, :stay_on_board)

      # The event's own pair names other trips, but the write's pair is the
      # drawer's: a crafted event cannot move the write off the pair the editor
      # is looking at (R5, AC-5). It writes that pair and nothing else.
      render_click(view, "save_connection", %{
        "from" => foreign_a.trip_id,
        "to" => foreign_b.trip_id
      })

      assert render_async(view)

      assert stored_transfers(context, foreign_a, foreign_b) == []
      assert [transfer] = stored_transfers(context, a, b)
      assert transfer.transfer_type == 4
      assert has_element?(view, "[data-role='connection-result']", "Saved:")
    end
  end
end
