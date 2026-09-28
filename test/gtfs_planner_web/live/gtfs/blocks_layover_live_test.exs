defmodule GtfsPlannerWeb.Gtfs.BlocksLayoverLiveTest do
  # EV-27: the Minimum layover drawer, observed through the ordinary
  # `/gtfs/:version/blocks` route on the production `CatalogReadAdapter.Repo` and
  # the scoped `Blocking` context, so a save reaches the real
  # `Gtfs.update_blocking_settings/3` → `Blocking.update_settings/3` upsert and the
  # reload that follows it. The fixture rows and the settings row the save writes
  # are created inside the SQL Sandbox transaction and rolled back.
  #
  # The focused gate command is deferred to branch review:
  # `mix test test/gtfs_planner_web/live/gtfs/blocks_layover_live_test.exs`.
  use GtfsPlannerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.BlockingFixtures
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.BlockingSetting
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
        route_long_name: "Riverside"
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

  defp calendar(context, service_id, name) do
    calendar_service_fixture(context.organization.id, context.version.id, %{
      service_id: service_id,
      name: name
    })
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

  # One block of two trips that hand off at the same stop after 7 minutes:
  # 7 ≥ the 5-minute default, so nothing is flagged until the minimum is raised
  # above it. Both endpoints use the same stop, so the only finding that can
  # appear is the layover one — the handoff itself is never an empty move.
  defp layover_scope(context) do
    calendar(context, "WK", "Weekday")

    stop =
      stop_fixture(context.organization.id, context.version.id, %{
        stop_id: "STOP_MAIN",
        stop_name: "Main St"
      })

    a =
      trip(context, %{
        trip_id: "a",
        block_id: "101",
        first: "08:00:00",
        last: "09:00:00",
        first_stop: stop.stop_id,
        last_stop: stop.stop_id
      })

    b =
      trip(context, %{
        trip_id: "b",
        block_id: "101",
        first: "09:07:00",
        last: "09:40:00",
        first_stop: stop.stop_id,
        last_stop: stop.stop_id
      })

    %{a: a, b: b, stop: stop}
  end

  defp open_day(context) do
    {:ok, view, _html} = live(editor_conn(context), blocks_path(context.version.id))
    view
  end

  defp open_layover(view), do: view |> element("#blocks-min-layover") |> render_click()

  defp change_layover(view, value) do
    view
    |> form("#layover-form", layover: %{min_layover_minutes: value})
    |> render_change()
  end

  defp submit_layover(view, value) do
    view
    |> form("#layover-form", layover: %{min_layover_minutes: value})
    |> render_submit()
  end

  defp doc(view), do: view |> render() |> LazyHTML.from_fragment()

  defp strip_value(view, key) do
    view
    |> doc()
    |> LazyHTML.query("#blocks-summary-counts-item-#{key}")
    |> LazyHTML.query("[data-role='count-strip-value']")
    |> LazyHTML.text()
    |> String.trim()
  end

  defp block_status(view, block_id) do
    view
    |> doc()
    |> LazyHTML.query(~s(#blocks-timeline tbody tr[data-block='#{block_id}']))
    |> LazyHTML.query("[data-role='block-status']")
    |> LazyHTML.text()
    |> String.trim()
  end

  defp stored_minimum(context) do
    Gtfs.get_blocking_settings(context.organization.id, context.version.id).min_layover_minutes
  end

  defp settings_rows, do: Repo.aggregate(BlockingSetting, :count)

  describe "the Minimum layover control" do
    setup :editor_scope

    test "prints the stored value and reads 5 without a stored row", context do
      layover_scope(context)

      view = open_day(context)

      # The read never stores the default: the button prints it, the table stays
      # empty and opening the drawer shows the same value in the field.
      assert has_element?(view, "#blocks-min-layover", "Minimum layover · 5 min")
      assert stored_minimum(context) == 5
      assert settings_rows() == 0

      open_layover(view)

      assert has_element?(view, "#layover-drawer-overlay[data-open='true']")
      assert has_element?(view, "#layover-drawer", "Minimum layover")
      assert has_element?(view, "#layover-form")
      assert has_element?(view, "#layover-minutes[value='5'][type='number']")
      assert has_element?(view, "#layover-minutes[min='0'][max='120'][step='1']")

      assert has_element?(
               view,
               "#layover-form label",
               "Minimum layover (minutes)"
             )

      assert has_element?(
               view,
               "#layover-minutes-help",
               "Flag connections shorter than this value. It applies to every day type in this version."
             )

      assert has_element?(view, "#layover-submit", "Save minimum")
      assert has_element?(view, "#layover-cancel", "Cancel")
      assert settings_rows() == 0
    end

    test "a change is validated before it is saved", context do
      layover_scope(context)

      view = open_day(context)
      open_layover(view)

      # The field carries the context's error as the reader types, so the value
      # is checked before a save is attempted.
      change_layover(view, "121")

      assert has_element?(view, "#layover-form", "must be a whole number between 0 and 120")
      assert has_element?(view, "#layover-minutes[value='121'][aria-invalid='true']")
      assert settings_rows() == 0

      # A valid change clears the error and still writes nothing.
      change_layover(view, "10")

      refute has_element?(view, "#layover-form", "must be a whole number between 0 and 120")
      assert has_element?(view, "#layover-minutes[value='10'][aria-invalid='false']")
      assert settings_rows() == 0
      assert stored_minimum(context) == 5
    end

    test "an out-of-range save shows a field error and keeps the value", context do
      layover_scope(context)

      view = open_day(context)
      open_layover(view)

      submit_layover(view, "121")

      assert has_element?(view, "#layover-form", "must be a whole number between 0 and 120")
      assert has_element?(view, "#layover-minutes[value='121'][aria-invalid='true']")
      assert has_element?(view, "#layover-drawer-overlay[data-open='true']")
      refute has_element?(view, "#flash-info")

      assert settings_rows() == 0
      assert stored_minimum(context) == 5
    end

    test "saving 10 stores it, reloads the day and makes a 7-minute gap short", context do
      layover_scope(context)

      other_version = gtfs_version_fixture(context.organization.id)
      view = open_day(context)

      # Before the save the 7-minute gap is at or above the 5-minute minimum, so
      # the day has no problems at all.
      assert strip_value(view, "problems") == "0"
      assert block_status(view, "101") == "No problems"

      open_layover(view)

      assert submit_layover(view, "10") =~ "Minimum layover saved."

      assert stored_minimum(context) == 10
      assert settings_rows() == 1

      # The value is this version's own: another version of the organization
      # keeps the default.
      assert Gtfs.get_blocking_settings(context.organization.id, other_version.id) == %{
               min_layover_minutes: 5
             }

      # The save closes the drawer, and the reloaded day re-derives the warnings
      # and the button's own value from the stored minimum.
      assert has_element?(view, "#layover-drawer-overlay[data-open='false']")
      assert has_element?(view, "#blocks-min-layover", "Minimum layover · 10 min")

      assert strip_value(view, "problems") == "1"
      assert block_status(view, "101") == "Short layover"

      view |> element("#blocks-review-checks") |> render_click()

      assert has_element?(
               view,
               "#checks-drawer-problems [data-role='blocks-finding'][data-code='short_layover']"
             )

      # Reopening the drawer shows the stored value, not the reader's last entry.
      view |> element("#checks-drawer-close") |> render_click()

      open_layover(view)

      assert has_element?(view, "#layover-minutes[value='10']")
    end

    test "a revoked editor role writes nothing and shows the permission message",
         %{membership: membership} = context do
      layover_scope(context)

      view = open_day(context)

      open_layover(view)
      change_layover(view, "10")
      assert has_element?(view, "#layover-minutes[value='10']")

      # No viewer role exists; a revoked editor is a membership with no roles.
      {:ok, _membership} = Accounts.update_user_org_membership(membership, %{roles: []})

      html = submit_layover(view, "10")

      assert html =~ "You don&#39;t have permission to change blocks in this version."

      # The sentence is shown in the open drawer's own alert slot, so it is visible
      # and not only in the page flash behind the top-layer <dialog> (AC-31).
      assert has_element?(
               view,
               "#layover-error",
               "You don't have permission to change blocks in this version."
             )

      assert settings_rows() == 0
      assert stored_minimum(context) == 5
      assert has_element?(view, "#blocks-min-layover", "Minimum layover · 5 min")
      assert strip_value(view, "problems") == "0"
      assert block_status(view, "101") == "No problems"
    end
  end
end
