defmodule GtfsPlannerWeb.Gtfs.FareEditorChecksTest do
  @moduledoc """
  Merge evidence for Checks, current journey pricing and export counts.
  The event regression for acceptance includes a forged browser amount: the
  persisted total must come from the authenticated version's current fare rows.
  """
  use GtfsPlannerWeb.ConnCase, async: false

  import Ecto.Query
  import GtfsPlanner.AccountsFixtures, only: [user_fixture: 1]
  import GtfsPlanner.OrganizationsFixtures, only: [organization_fixture: 1]
  import GtfsPlanner.VersionsFixtures, only: [gtfs_version_fixture: 2]
  import Phoenix.LiveViewTest

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.FaresFixtures
  alias GtfsPlanner.Gtfs.AuditContext
  alias GtfsPlanner.Gtfs.Fares
  alias GtfsPlanner.Gtfs.Fares.Conversion
  alias GtfsPlanner.Gtfs.FareSavedJourney
  alias GtfsPlanner.Repo
  alias GtfsPlanner.Support.StagedImport

  setup context do
    organization =
      organization_fixture(%{alias: "fare-checks-#{System.unique_integer([:positive])}"})

    user = user_fixture(%{email: "fare-checks-#{System.unique_integer([:positive])}@example.com"})

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

  test "lists fare checks and shows scoped journey and export sections", ctx do
    version = managed(ctx)
    view = open_checks(ctx, version)

    assert has_element?(view, "#fare-problems")
    assert has_element?(view, "#journey-check")
    assert has_element?(view, "#journey-result[aria-live='polite']")
    assert has_element?(view, "#saved-journeys")
    assert has_element?(view, "#formats")
    assert view |> element("#formats") |> render() =~ "5"
  end

  test "acceptance ignores a forged amount and persists the scoped server repricing", ctx do
    version = managed(ctx)
    journey = saved_journey(ctx, version)

    # Make the saved expectation differ so the normal UI marks it for acceptance.
    journey =
      Repo.update!(Ecto.Changeset.change(journey, %{expected_amount: Decimal.new("0.01")}))

    view = open_checks(ctx, version)
    assert has_element?(view, "#saved-journeys")

    # The browser can still send the old amount parameter, but the handler must
    # ignore it and calculate the current $1.50 from this version's fare rows.
    render_click(view, "accept_journey_price", %{
      "journey_id" => journey.id,
      "amount" => "0.02"
    })

    persisted = Repo.get!(FareSavedJourney, journey.id)
    assert Decimal.equal?(persisted.expected_amount, Decimal.new("1.50"))
    assert render(view) =~ "now expects $1.50"
  end

  defp managed(ctx) do
    version = gtfs_version_fixture(ctx.organization.id, %{name: "North Coast checks"})
    path = FaresFixtures.fixture_path!("north_coast_v2")

    files =
      path
      |> File.ls!()
      |> Enum.filter(&(Path.extname(&1) == ".txt"))
      |> Enum.sort()
      |> Enum.map(fn filename ->
        %{filename: filename, content: File.read!(Path.join(path, filename))}
      end)

    assert {:ok, _} = StagedImport.import_files(ctx.organization.id, version.id, files)
    {:ok, plan} = Conversion.preview(ctx.organization.id, version.id)
    assert {:ok, _} = Conversion.apply(scope(ctx, version), plan.fingerprint, [])
    version
  end

  defp saved_journey(ctx, version) do
    assert {:ok, %{journey: journey}} =
             Fares.save_journey(scope(ctx, version), %{
               name: "Newport local",
               rider_category_id: "adult",
               fare_media_id: "cash",
               service_date: ~D[2026-10-01],
               legs: [
                 %{
                   route_id: "1",
                   from_stop_id: "NTC",
                   to_stop_id: "NYE",
                   departs: 27_600,
                   arrives: 27_600
                 }
               ]
             })

    journey
  end

  defp open_checks(ctx, version) do
    {:ok, view, _html} = live(ctx.conn, ~p"/gtfs/#{version.id}/settings/fares/checks")
    view
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
