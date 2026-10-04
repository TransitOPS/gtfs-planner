defmodule GtfsPlannerWeb.Gtfs.FareAssistanceBoundariesTest do
  @moduledoc """
  Merge evidence (EV-16) for the cross-host boundaries of the two Fares helpers:
  forged handoff events, an editor revoked between preparation and confirm, a
  replaced conversation, a forced open on an unmanaged version and a provider
  failure, on the Fare zones page and the managed Prices tab.

  Every case mounts the real page through an authenticated session, asserts the
  legitimate control renders before it delivers the forged event, and reads the
  stored zones, prices and change log back to show nothing changed. The expected
  zones and prices are literals from `GtfsPlanner.FareSelectionFixtures` and the
  `north_coast_v2` fixture. Independent-connection locking is EV-4's.
  """
  use GtfsPlannerWeb.ConnCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.Agents.PackTurn
  import GtfsPlanner.FaresFixtures, only: [import!: 3, managed!: 3]
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Agents
  alias GtfsPlanner.Agents.Scope
  alias GtfsPlanner.FareSelectionFixtures
  alias GtfsPlanner.Gtfs.ChangeLog
  alias GtfsPlanner.Gtfs.FareProduct
  alias GtfsPlanner.Gtfs.Stop
  alias GtfsPlanner.Repo

  @zone_arguments ~s({"route_ids":["R6"],"only_unzoned":true,"exclude_stop_ids":["AIR1"],"zone_id":"B"})
  @price_arguments Jason.encode!(%{
                     "currency" => "USD",
                     "changes" => [
                       %{
                         "fare_product_id" => "local_ride_adult_cash",
                         "rider_category_id" => "adult",
                         "fare_media_id" => "cash",
                         "amount" => "1.75"
                       }
                     ]
                   })

  @unavailable_zone "That prepared assignment is no longer available. Ask the helper again."
  @unavailable_price "That prepared change is no longer available. Ask the helper again."

  setup {Req.Test, :verify_on_exit!}

  setup do
    setup_conversations()

    organization = organization_fixture()
    user = user_fixture()
    membership = organization_membership_fixture(user, organization)

    %{organization: organization, user: user, membership: membership}
  end

  describe "the Fare zones page" do
    setup context do
      version = gtfs_version_fixture(context.organization.id, %{name: "Boundary Zones"})
      stops = FareSelectionFixtures.insert_network!(context.organization, version)
      FareSelectionFixtures.declare_zone!(context.organization, version, "B")

      %{version: version, stops: stops}
    end

    test "a forged entry, a replaced conversation and an editor revoked before confirm",
         context do
      {view, pid} = prepared(context, "zones", "prepare_zone_assignment", @zone_arguments)
      assert has_element?(view, "#agent-review-prepared-2")
      before = {zones(), Repo.aggregate(ChangeLog, :count)}

      render_click(view, "agent_review_prepared", %{"entry" => "999"})

      assert has_element?(view, "#agent-panel", @unavailable_zone)
      refute has_element?(view, "#fare-zone-assignment-dialog")
      assert {zones(), Repo.aggregate(ChangeLog, :count)} == before

      # A replaced conversation takes its cards with it.
      view |> element("#agent-new-conversation") |> render_click()
      assert_receive {:agent_event, ^pid, {:reset, _conversation_id}}, 5_000
      render(view)

      refute has_element?(view, "#agent-review-prepared-2")
      render_click(view, "agent_review_prepared", %{"entry" => "2"})
      assert has_element?(view, "#agent-panel", @unavailable_zone)
      refute has_element?(view, "#fare-zone-assignment-dialog")

      # A fresh turn prepares a fresh card; the editor loses access before confirming.
      run_prepare(view, pid, "prepare_zone_assignment", @zone_arguments)
      view |> element("#agent-review-prepared-2") |> render_click()
      assert has_element?(view, "#fare-zone-assignment-dialog")

      deactivate_membership_fixture(context.membership)
      view |> element("#fare-zone-assignment-dialog-confirm") |> render_click()

      assert {zones(), Repo.aggregate(ChangeLog, :count)} == before
      assert has_element?(view, "#fare-zone-assignment-error")
    end

    test "a provider failure leaves the native review usable", context do
      {:ok, view, _html} = open(context, "zones")
      view |> element("#agent-helper-open") |> render_click()
      pid = assigns(view).agent_session
      assert {:ok, ^pid, _snapshot} = Agents.open(scope(context, "fare_zones"))

      expect_failure(500)

      view
      |> element("#agent-composer")
      |> render_submit(%{"agent" => %{"message" => "Put those stops in Zone B"}})

      assert_receive {:agent_event, ^pid, {:entry, %{role: :assistant, status: :failed}}}, 10_000
      render(view)
      assert assigns(view).agent_unavailable?

      render_click(view, "toggle_stop", %{"id" => context.stops["A1"].id})
      view |> element("#fare-zone-assign-selection") |> render_click()

      assert has_element?(view, "#fare-zone-assignment-dialog")
      assert has_element?(view, "#fare-zone-assignment-row-1", "Alder")
    end
  end

  describe "the Prices tab" do
    setup context do
      version = gtfs_version_fixture(context.organization.id, %{name: "Boundary Prices"})
      managed!(context.organization, version, context.user)

      %{version: version}
    end

    test "a forged entry, a replaced conversation and an editor revoked before confirm",
         context do
      {view, pid} = prepared(context, "prices", "prepare_price_changes", @price_arguments)
      assert has_element?(view, "#agent-review-prepared-2")
      before = {prices(context), Repo.aggregate(ChangeLog, :count)}

      render_click(view, "agent_review_prepared", %{"entry" => "999"})

      assert has_element?(view, "#agent-panel", @unavailable_price)
      refute has_element?(view, "#price-review-dialog")
      assert {prices(context), Repo.aggregate(ChangeLog, :count)} == before

      view |> element("#agent-new-conversation") |> render_click()
      assert_receive {:agent_event, ^pid, {:reset, _conversation_id}}, 5_000
      render(view)

      refute has_element?(view, "#agent-review-prepared-2")
      render_click(view, "agent_review_prepared", %{"entry" => "2"})
      assert has_element?(view, "#agent-panel", @unavailable_price)
      refute has_element?(view, "#price-review-dialog")

      run_prepare(view, pid, "prepare_price_changes", @price_arguments)
      view |> element("#agent-review-prepared-2") |> render_click()
      assert has_element?(view, "#price-review-dialog")

      deactivate_membership_fixture(context.membership)
      view |> element("#price-review-dialog-confirm") |> render_click()

      assert {prices(context), Repo.aggregate(ChangeLog, :count)} == before
      assert has_element?(view, "#price-review-error")
    end

    test "a provider failure leaves the grid editable", context do
      {:ok, view, _html} = open(context, "prices")
      view |> element("#agent-helper-open") |> render_click()
      pid = assigns(view).agent_session
      assert {:ok, ^pid, _snapshot} = Agents.open(scope(context, "fare_prices"))

      expect_failure(500)

      view
      |> element("#agent-composer")
      |> render_submit(%{"agent" => %{"message" => "Raise Local ride adult cash"}})

      assert_receive {:agent_event, ^pid, {:entry, %{role: :assistant, status: :failed}}}, 10_000
      render(view)
      assert assigns(view).agent_unavailable?

      view
      |> element("#fare-table-form")
      |> render_change(%{"price" => %{"local_ride_adult_cash|adult|cash" => "1.80"}})

      assert has_element?(view, "#save-prices")
    end

    test "a forced open on an unmanaged version reads and changes nothing", context do
      unmanaged = gtfs_version_fixture(context.organization.id, %{name: "Boundary Unmanaged"})
      import!(context.organization, unmanaged, "north_coast_v1")
      context = %{context | version: unmanaged}

      {:ok, view, _html} = open(context, "prices")
      refute has_element?(view, "#agent-helper-open")

      before = prices(context)

      # Forced open: the panel's own event is not guarded by the hidden button. The
      # page still renders no panel for a version it cannot help with, and the
      # conversation it opened refuses every price read.
      render_click(view, "agent_open", %{})
      refute has_element?(view, "#agent-panel")
      pid = assigns(view).agent_session
      assert is_pid(pid)
      assert {:ok, ^pid, _snapshot} = Agents.open(scope(context, "fare_prices"))

      expect_reply(tool_calls_reply([{"call_1", "list_price_cells", "{}"}]))
      expect_reply(text_reply("I could not read the prices."))

      assert :ok = Agents.send_message(pid, "Which prices are there?")

      assert %{"error" => message} = tool_result()

      assert message ==
               "This version's fares are not edited here yet. Set them up or convert them on the Prices tab first."

      assert_receive {:agent_event, ^pid, {:entry, %{role: :assistant, status: :done}}}, 10_000
      assert prices(context) == before
    end
  end

  ## Helpers

  defp log_in(conn, context),
    do: log_in_user(conn, context.user, organization: context.organization)

  defp open(context, "zones"),
    do:
      build_conn() |> log_in(context) |> live("/gtfs/#{context.version.id}/settings/fares/zones")

  defp open(context, "prices"),
    do: build_conn() |> log_in(context) |> live("/gtfs/#{context.version.id}/settings/fares")

  defp assigns(view), do: :sys.get_state(view.pid).socket.assigns

  defp zones,
    do: Repo.all(from(s in Stop, order_by: s.id, select: {s.id, s.zone_id, s.updated_at}))

  defp prices(context) do
    Repo.all(
      from(p in FareProduct,
        where: p.gtfs_version_id == ^context.version.id,
        order_by: [p.fare_product_id, p.rider_category_id, p.fare_media_id],
        select: {p.fare_product_id, p.rider_category_id, p.fare_media_id, p.amount, p.updated_at}
      )
    )
  end

  defp scope(context, pack_id) do
    %Scope{
      organization_id: context.organization.id,
      gtfs_version_id: context.version.id,
      user_id: context.user.id,
      user_email: context.user.email,
      pack_id: pack_id,
      version_name: context.version.name,
      resource_context: Scope.context({:version, context.version.id})
    }
  end

  # Opens the helper on a host and runs one scripted prepare turn, so the prepared
  # card renders before a forged event is delivered.
  defp prepared(context, host, tool, arguments) do
    pack_id = if host == "zones", do: "fare_zones", else: "fare_prices"

    {:ok, view, _html} = open(context, host)
    view |> element("#agent-helper-open") |> render_click()

    pid = assigns(view).agent_session
    assert {:ok, ^pid, _snapshot} = Agents.open(scope(context, pack_id))

    run_prepare(view, pid, tool, arguments)
    {view, pid}
  end

  defp run_prepare(view, pid, tool, arguments) do
    expect_reply(tool_calls_reply([{"call_1", tool, arguments}]))
    expect_reply(text_reply("I prepared it."))

    view
    |> element("#agent-composer")
    |> render_submit(%{"agent" => %{"message" => "Prepare that change"}})

    assert_receive {:agent_event, ^pid, {:entry, %{status: :done, prepared: %{}}}}, 10_000
    render(view)
  end
end
