defmodule GtfsPlannerWeb.Gtfs.StopsMapReplaceTest do
  @moduledoc """
  Tests for the replace panel.

  Four things are claimed. The candidates are the nearest stops, in order, in
  the reader's own units; a click on the map chooses the stop to keep rather
  than opening the stop that was clicked, because the panel is a question about
  which stop to keep; a choice the command refuses is refused in words, with no
  apply button beside it; and an accepted replace moves the references and, when
  the editor asks for it, deletes the old stop.

  The refusal case is the one that would pass behind "the command refuses". What
  is checked is the sentence — "twice in a row" — and the absence of the button,
  because a panel that renders a refusal and still offers the button is asking
  the editor to press it twice.

  The distances are literals, and the seeds are written through the same tables
  the commands read.
  """
  use GtfsPlannerWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import Mox, only: [set_mox_global: 1]
  import Phoenix.LiveViewTest
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.GeocodingMock
  alias GtfsPlanner.Gtfs.RoutePatternStop
  alias GtfsPlanner.Gtfs.Stop
  alias GtfsPlanner.Repo

  # 1.5 m, which the panel states as the "5 ft apart" the checks list already
  # uses for this pair.
  @metres_per_degree 111_320.0
  @base_lat 44.6210
  @base_lon -124.0530

  setup :set_mox_global

  setup do
    organization = organization_fixture()
    editor = user_fixture()

    Accounts.create_user_org_membership(%{
      user_id: editor.id,
      organization_id: organization.id,
      roles: ["pathways_studio_editor"]
    })

    version = gtfs_version_fixture(organization.id)

    ctx = %{
      organization: organization,
      version: version,
      editor: editor,
      editor_conn: log_in_user(build_conn(), editor, organization: organization)
    }

    {:ok, Map.put(ctx, :fixture, seeded(ctx))}
  end

  describe "the candidates" do
    test "replace on 1433 lists 1434 first, 5 ft away", ctx do
      view = open_replace(ctx, "1433")

      assert has_element?(view, "#stops-map-replace-panel")
      assert has_element?(view, "#stops-map-replace-heading", "Replace US 101 & SE 1st St")

      # Nearest first, and the nearest is the pair the checks list already
      # reports as 5 ft apart.
      first = view |> element("#stops-map-replace-candidate-1434") |> render()

      assert first =~ "Main St &amp; 1st"
      assert first =~ "5 ft away"

      # The chosen stop is chosen, not blank: the panel opens on an answer so
      # the review below it is about a specific pair.
      assert view
             |> element("#stops-map-replace-candidates input[value='1434'][checked]")
             |> has_element?()
    end

    test "selecting a stop on the map chooses it instead of opening it", ctx do
      view = open_replace(ctx, "1433")

      assert has_element?(view, "#stops-map-replace-panel")

      # A click the map makes on a stop the panel did not offer. The panel stays
      # the replace panel and the choice changes; nothing is opened.
      render_click(view, "select_stop", %{"stop_id" => "1500"})

      assert settle(view) |> has_element?("#stops-map-replace-panel")
      refute has_element?(view, "#stops-map-edit-panel")

      assert view
             |> element("#stops-map-replace-candidates input[value='1500'][checked]")
             |> has_element?()

      assert has_element?(view, "#stops-map-replace-changes")
    end
  end

  describe "a refused replace" do
    test "choosing the stop a pattern already visits next shows the refusal in words", ctx do
      view = open_replace(ctx, "1433")

      # A pattern visits 1433 and then 1391, so replacing 1433 with 1391 would
      # visit it twice in a row.
      assert visit_order(ctx, "REPLACE_A") == ["1433", "1391"]

      render_click(view, "choose_replace", %{"stop_id" => "1391"})

      assert settle(view) |> has_element?("#stops-map-replace-refused")

      assert view |> element("#stops-map-replace-refused-message") |> render() =~
               "twice in a row"

      # Nothing to press: the command would refuse this pair again.
      refute has_element?(view, "#stops-map-replace-go")
      assert stop_exists?(ctx, "1433")
      assert visit_order(ctx, "REPLACE_A") == ["1433", "1391"]
    end
  end

  describe "an accepted replace" do
    test "in one pattern with delete checked, 1433 goes and 1434 is selected", ctx do
      view = open_replace(ctx, "1433")

      assert has_element?(view, "#stops-map-replace-go")
      assert has_element?(view, "#stops-map-replace-go", "Replace in 1 pattern")

      # The checkbox is checked by default, as the reference has it: replacing a
      # duplicate and leaving both stops in the feed is the state nobody wants.
      assert has_element?(view, "#stops-map-replace-delete-old[checked]")

      view |> element("#stops-map-replace-go") |> render_click()

      assert settle(view) |> has_element?("#stops-map-edit-panel")
      refute has_element?(view, "#stops-map-replace-panel")

      # The pattern now stops at the stop that was kept…
      assert visit_order(ctx, "REPLACE_A") == ["1434", "1391"]
      # …the old stop is gone, because the editor asked for that…
      refute stop_exists?(ctx, "1433")
      # …and the editor is left on the stop that is now the stop.
      assert view |> element("#stops-map-edit-panel h2") |> render() =~ "Main St"
    end

    test "unchecking the box keeps the old stop in the feed", ctx do
      view = open_replace(ctx, "1433")

      view |> element("#stops-map-replace-delete-old") |> render_click()
      view |> element("#stops-map-replace-go") |> render_click()

      assert settle(view) |> has_element?("#stops-map-edit-panel")
      assert stop_exists?(ctx, "1433")
      assert visit_order(ctx, "REPLACE_A") == ["1434", "1391"]
    end
  end

  # --- fixture ---------------------------------------------------------------

  # 1433 is the stop with something to move away; 1434 is the duplicate 1.5 m
  defp seeded(ctx) do
    stops =
      Map.new(
        [
          {"1433", "US 101 & SE 1st St", 0.0},
          {"1434", "Main St & 1st", 1.5},
          {"1391", "Bay Blvd", 40.0},
          {"1500", "Harbour Way", 120.0}
        ],
        fn {id, name, offset} ->
          {id,
           stop_fixture(ctx.organization.id, ctx.version.id, %{
             stop_id: id,
             stop_name: name,
             stop_lat: Decimal.from_float(@base_lat + offset / @metres_per_degree),
             stop_lon: Decimal.from_float(@base_lon)
           })}
        end
      )

    route = route_fixture(ctx.organization.id, ctx.version.id, %{route_short_name: "1"})

    # One pattern, visiting 1433 and then 1391. That is what makes replacing
    # 1433 with 1391 a refusal, and replacing it with anything else a
    # single-pattern change the apply button can name.
    pattern =
      route_pattern_fixture(ctx.organization.id, ctx.version.id, %{
        route_pattern_id: "REPLACE_A",
        route_id: route.route_id,
        direction_id: 0,
        headsign: "To Bay Blvd"
      })

    route_pattern_stop_fixture(pattern, "1433", 1)
    route_pattern_stop_fixture(pattern, "1391", 2)

    stops
  end

  defp stop_exists?(ctx, stop_id) do
    Repo.exists?(
      from(s in Stop,
        where:
          s.organization_id == ^ctx.organization.id and s.gtfs_version_id == ^ctx.version.id and
            s.stop_id == ^stop_id
      )
    )
  end

  defp settle(view, rounds \\ 8)
  defp settle(view, 0), do: view

  defp settle(view, rounds) do
    render_async(view, 5_000)
    settle(view, rounds - 1)
  end

  defp open_replace(ctx, stop_id) do
    view = open_stop(ctx, stop_id)

    view |> element("#stops-map-edit-more") |> render_click()
    view |> element("#stops-map-edit-replace") |> render_click()

    settle(view)
  end

  defp open_stop(ctx, stop_id) do
    path = "/gtfs/#{ctx.version.id}/stops/map?stop=#{stop_id}"
    {:ok, view, _html} = live(ctx.editor_conn, path)
    settle(view)

    Mox.stub(GeocodingMock, :autocomplete, fn _text, _opts -> {:ok, []} end)
    Mox.allow(GeocodingMock, self(), view.pid)

    assert has_element?(view, "#stops-map-edit-panel")

    view
  end

  # A pattern's visits in the order the feed will run them, read back from the
  # rows the commands write rather than from anything the panel rendered.
  defp visit_order(ctx, route_pattern_id) do
    ctx
    |> pattern_visits(route_pattern_id)
    |> Enum.map(& &1.stop_id)
  end

  defp pattern_visits(ctx, route_pattern_id) do
    from(rps in RoutePatternStop,
      join: p in assoc(rps, :route_pattern),
      where:
        p.organization_id == ^ctx.organization.id and p.gtfs_version_id == ^ctx.version.id and
          p.route_pattern_id == ^route_pattern_id,
      order_by: [asc: rps.position],
      select: rps
    )
    |> Repo.all()
  end
end
