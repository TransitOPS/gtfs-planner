defmodule GtfsPlannerWeb.Gtfs.FareEditorSetupTest do
  @moduledoc """
  Merge evidence (EV-35) for the Prices tab's setup, fare-free, imported and
  mismatch states: what each one shows, what it writes, and what it refuses
  (AC-38).

  Every case drives the real page against the real writers — through
  `GtfsPlanner.Gtfs.Fares.Conversion.setup/2`, `Conversion.preview/2`,
  `Conversion.apply/3` and `Fares.set_older_format/2` — and asserts on the
  elements the states are required to carry rather than on the words they happen
  to read.

  The versions enter their rows the way a user's versions do: through the
  production importer (`no_fare` holds the sample's routes and stops with no fare
  files at all, `north_coast_v1` holds the sample's older-format fares, and
  `refused/leg_groups` holds a Fares v2 feed whose imported route groups cannot
  map onto networks) and, where a conversion is what makes a version editable,
  through the production conversion that manages it.

  The expected amounts are worked by hand from those feeds: `north_coast_v1`
  prices LOCAL at $1.50 on board with two free transfers within 90 minutes, and
  the mismatch case is the same feed after somebody edits the stored $1.50 row to
  $1.75 the way a later import of an edited feed leaves it.
  """
  use GtfsPlannerWeb.ConnCase, async: false

  import Ecto.Query
  import GtfsPlanner.AccountsFixtures, only: [user_fixture: 1]
  import GtfsPlanner.FaresFixtures, only: [import!: 3]
  import GtfsPlanner.OrganizationsFixtures, only: [organization_fixture: 1]
  import GtfsPlanner.VersionsFixtures, only: [gtfs_version_fixture: 2]
  import Phoenix.LiveViewTest

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Gtfs.AuditContext
  alias GtfsPlanner.Gtfs.FareAttribute
  alias GtfsPlanner.Gtfs.Fares
  alias GtfsPlanner.Gtfs.Fares.Conversion
  alias GtfsPlanner.Repo

  setup context do
    organization =
      organization_fixture(%{alias: "fare-setup-#{System.unique_integer([:positive])}"})

    user = user_fixture(%{email: editor_email()})

    Accounts.create_user_org_membership(%{
      user_id: user.id,
      organization_id: organization.id,
      roles: ["pathways_studio_editor"]
    })

    {:ok,
     conn: log_in_user(context.conn, user, organization: organization),
     organization: organization,
     user: user}
  end

  describe "the first-use setup" do
    test "a version with no fares asks the four questions instead of drawing the grid", ctx do
      version = version(ctx, "Blank fare version", "no_fare")
      view = open_prices(ctx, version)

      assert has_element?(view, "#fare-setup")
      refute has_element?(view, "#fare-table")

      # The one primary lives in the panel that answers the questions, so the
      # header carries none while the setup is on screen.
      refute has_element?(view, "#create-fare")
      assert has_element?(view, "#setup-create")
      assert has_element?(view, "#setup-step-1")
      assert has_element?(view, "#setup-step-3")

      # The live result card reads the draft: one price for every ride, a reduced
      # fare at half of it, and free young children.
      result = view |> element("#setup-result") |> render()
      assert result =~ "$1.50"
      assert result =~ "Reduced fare $0.75"
      assert result =~ "1 fare, 3 rider types, 1 transfer rule"
    end

    test "Create fares with a flat $1.50 writes the fare set and shows the Prices grid", ctx do
      version = version(ctx, "Flat fare version", "no_fare")
      view = open_prices(ctx, version)

      view
      |> element("#fare-setup-form")
      |> render_submit(%{
        "setup" => %{
          "kind" => "flat",
          "adult" => "1.50",
          "reduced" => "true",
          "transfer" => "true",
          "minutes" => "90"
        }
      })

      refute has_element?(view, "#fare-setup")
      assert has_element?(view, "#fare-table")

      # `Conversion.setup/2` writes one product row per chosen rider type, each
      # at half the adult price or nothing, and manages the version.
      {:ok, workspace} = Fares.load_workspace(ctx.organization.id, version.id)
      assert workspace.managed?
      assert [%{name: "Local ride"}] = workspace.fares

      assert same_prices?(workspace.fares |> hd() |> Map.fetch!(:prices), %{
               "adult" => "1.50",
               "reduced" => "0.75",
               "child" => "0.00"
             })

      # A grid cell is editable now, and the header's own primary is back.
      assert has_element?(view, "#price-local_ride-adult")
      assert has_element?(view, "#create-fare")

      # Undo reverses the whole write and leaves the version with no fares, so
      # the setup is what it opens on again.
      view |> element("#undo-prices") |> render_click()
      refute has_element?(view, "#fare-table")
      assert has_element?(view, "#fare-setup")
      refute Fares.managed?(ctx.organization.id, version.id)
    end

    test "a setup submitted twice cannot write over the fares it already created", ctx do
      version = version(ctx, "Twice fare version", "no_fare")
      view = open_prices(ctx, version)

      view
      |> element("#fare-setup-form")
      |> render_submit(%{"setup" => %{"kind" => "flat", "adult" => "1.50"}})

      assert has_element?(view, "#fare-table")

      # The setup is gone once the version holds a fare, so a late submit — a
      # debounced keystroke crossing the write — has no form to reach a writer.
      render_submit(view, "create_fares", %{"setup" => %{"kind" => "flat", "adult" => "9.99"}})

      {:ok, workspace} = Fares.load_workspace(ctx.organization.id, version.id)
      assert [%{name: "Local ride"}] = workspace.fares

      assert same_prices?(workspace.fares |> hd() |> Map.fetch!(:prices), %{
               "adult" => "1.50",
               "reduced" => "0.75",
               "child" => "0.00"
             })
    end

    test "the free structure writes one free fare and the fare-free summary replaces the grid",
         ctx do
      version = version(ctx, "Free fare version", "no_fare")
      view = open_prices(ctx, version)

      view
      |> element("#fare-setup-form")
      |> render_submit(%{"setup" => %{"kind" => "free"}})

      refute has_element?(view, "#fare-table")
      assert has_element?(view, "#fare-free")
      assert has_element?(view, "#start-charging-fares")
      refute has_element?(view, "#create-fare")

      {:ok, workspace} = Fares.load_workspace(ctx.organization.id, version.id)
      assert [%{name: "Free ride"}] = workspace.fares
      assert same_prices?(workspace.fares |> hd() |> Map.fetch!(:prices), %{"adult" => "0.00"})

      # "Start charging fares" opens the fare drawer for the fare the setup wrote
      # — the same drawer the grid's own fare names open.
      view |> element("#start-charging-fares") |> render_click()
      assert has_element?(view, "#fare-drawer")
      assert view |> element("#fare-name") |> render() =~ "Free ride"
    end

    test "an answer the writer will not read is refused on the field it names", ctx do
      version = version(ctx, "Refused fare version", "no_fare")
      view = open_prices(ctx, version)

      view
      |> element("#fare-setup-form")
      |> render_submit(%{"setup" => %{"kind" => "flat", "adult" => "one fifty"}})

      # Nothing was written and the version is still the first-use setup.
      assert has_element?(view, "#fare-setup")
      refute Fares.managed?(ctx.organization.id, version.id)
      assert has_element?(view, "#setup-error-summary")
      assert has_element?(view, "#setup-adult-error")
    end
  end

  describe "an imported version" do
    test "its fares are read-only until the conversion review converts them", ctx do
      version = version(ctx, "Unmanaged v1 version", "north_coast_v1")
      view = open_prices(ctx, version)

      assert has_element?(view, "#unmanaged-fares")
      assert has_element?(view, "#edit-fares")
      refute has_element?(view, "#create-fare")

      # Nothing on the page can be typed into: every writer of this package
      # refuses an unmanaged version.
      refute has_element?(view, "#fare-table input[name^='price[']")
      refute has_element?(view, "#change-prices")
      assert view |> element("#unmanaged-v1-table") |> render() =~ "LOCAL"

      view |> element("#edit-fares") |> render_click()

      assert has_element?(view, "#conversion-review")
      assert has_element?(view, "#conversion-review-confirm")

      # North Coast's five older-format fares convert with no price difference,
      # two differences R12 records rather than refuses, and the `contains_id`
      # rule kept in the older format.
      assert view |> element("#conversion-price-differences") |> render() =~ "0"
      assert view |> element("#conversion-counts") |> render() =~ "5 fares"
      assert has_element?(view, "#conversion-known-differences")
      assert view |> element("#conversion-kept-older") |> render() =~ "COAST"

      view |> element("#conversion-review-confirm") |> render_click()

      refute has_element?(view, "#conversion-review")

      # The version is managed now, so the grid is editable.
      assert Fares.managed?(ctx.organization.id, version.id)
      assert has_element?(view, "#fare-table")
      assert has_element?(view, "#fare-table input[name^='price[']")
      assert has_element?(view, "#create-fare")

      # Every stored older-format row is left exactly as it was (INV-3).
      assert stored_prices(ctx, version) == %{
               "COAST" => Decimal.new("3.50"),
               "INTERCITY" => Decimal.new("6.00"),
               "LOCAL" => Decimal.new("1.50"),
               "VALCOAST" => Decimal.new("5.00"),
               "VALLEY" => Decimal.new("2.50")
             }
    end

    test "a refused review states the reasons and offers no Convert button", ctx do
      version = version(ctx, "Refused conversion version", "refused/leg_groups")
      view = open_prices(ctx, version)

      # The stored Fares v2 products are drawn read-only, through the same grid.
      assert has_element?(view, "#unmanaged-fares")
      assert has_element?(view, "#fare-table")
      refute has_element?(view, "#fare-table input[name^='price[']")

      view |> element("#edit-fares") |> render_click()

      assert has_element?(view, "#conversion-review")
      assert has_element?(view, "#conversion-review-refused")
      assert has_element?(view, "#conversion-refusal-leg_groups")

      assert view |> element("#conversion-refusal-leg_groups") |> render() =~
               "route groups do not map one-to-one onto networks"

      # There is nothing to press: a refused review offers Close alone.
      refute has_element?(view, "#conversion-review-confirm")
      assert has_element?(view, "#conversion-review-cancel")

      view |> element("#conversion-review-cancel") |> render_click()
      refute has_element?(view, "#conversion-review")

      # And nothing was written by opening or closing it.
      refute Fares.managed?(ctx.organization.id, version.id)
    end
  end

  describe "the mismatch banner" do
    test "it appears for the fares the two descriptions disagree about and can be kept", ctx do
      version = version(ctx, "Mismatch version", "north_coast_v1")
      {:ok, plan} = Conversion.preview(ctx.organization.id, version.id)
      {:ok, _converted} = Conversion.apply(scope(ctx, version), plan.fingerprint, [])

      # The stored row is edited the way a later import of an edited feed leaves
      # it: `Fares` never edits one (INV-3).
      {1, nil} =
        FareAttribute
        |> where(
          [attribute],
          attribute.organization_id == ^ctx.organization.id and
            attribute.gtfs_version_id == ^version.id and attribute.fare_id == "LOCAL"
        )
        |> Repo.update_all(set: [price: Decimal.new("1.75"), updated_at: DateTime.utc_now()])

      view = open_prices(ctx, version)

      assert has_element?(view, "#fares-mismatch")
      detail = view |> element("#fares-mismatch-detail") |> render()
      assert detail =~ "LOCAL"
      assert detail =~ "$1.75"
      assert detail =~ "$1.50"

      view |> element("#keep-older-format") |> render_click()

      assert Fares.settings(ctx.organization.id, version.id).older_format == "imported"
      refute has_element?(view, "#fares-mismatch")

      # The stored price is what an export streams now.
      assert stored_prices(ctx, version)["LOCAL"] == Decimal.new("1.75")
    end

    test "a version whose stored and derived fares agree carries no banner", ctx do
      version = version(ctx, "Agreeing version", "north_coast_v1")
      {:ok, plan} = Conversion.preview(ctx.organization.id, version.id)
      {:ok, _converted} = Conversion.apply(scope(ctx, version), plan.fingerprint, [])

      view = open_prices(ctx, version)

      refute has_element?(view, "#fares-mismatch")
      assert has_element?(view, "#fare-table")
    end
  end

  # -- Helpers ------------------------------------------------------------------

  # A per-call address: the shared `user_fixture/1` counter restarts with each
  # BEAM run, so a row an unboxed test left in the shared database can collide
  # with it inside the fixture. The prefix keeps this file out of that range.
  defp editor_email do
    "fare-setup-#{System.pid()}-#{System.unique_integer([:positive])}@example.com"
  end

  defp version(ctx, name, fixture) do
    version = gtfs_version_fixture(ctx.organization.id, %{name: name})
    import!(ctx.organization, version, fixture)
    version
  end

  defp open_prices(ctx, version) do
    {:ok, view, _html} = live(ctx.conn, ~p"/gtfs/#{version.id}/settings/fares")

    # The shell's connected mount owns the load, so the tab body only renders
    # once the workspace has arrived.
    assert render(view) =~ "fare-editor-panel"
    view
  end

  defp stored_prices(ctx, version) do
    FareAttribute
    |> where(
      [attribute],
      attribute.organization_id == ^ctx.organization.id and
        attribute.gtfs_version_id == ^version.id
    )
    |> select([attribute], {attribute.fare_id, attribute.price})
    |> Repo.all()
    |> Map.new()
  end

  # Two price maps are the same when every rider type carries the same amount,
  # compared as amounts rather than as decimals' own scale — `Decimal.new/1`
  # keeps the digits it was given, so `$0` and `$0.00` are equal amounts and
  # unequal structs.
  defp same_prices?(prices, expected) do
    Map.keys(prices) == Map.keys(expected) and
      Enum.all?(expected, fn {rider_id, amount} ->
        Decimal.equal?(Map.fetch!(prices, rider_id), Decimal.new(amount))
      end)
  end

  defp scope(ctx, version) do
    %{
      organization_id: ctx.organization.id,
      gtfs_version_id: version.id,
      audit: %AuditContext{
        organization_id: ctx.organization.id,
        gtfs_version_id: version.id,
        station_stop_id: nil,
        actor_id: ctx.user.id,
        actor_email: ctx.user.email
      }
    }
  end
end
