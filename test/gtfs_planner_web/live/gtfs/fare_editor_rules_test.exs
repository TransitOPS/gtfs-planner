defmodule GtfsPlannerWeb.Gtfs.FareEditorRulesTest do
  @moduledoc """
  Merge evidence (EV-37) for fare time periods and the leg-rule drawer/list.

  Tests use the production import/conversion and drive the real FareEditorLive
  writer events through SQL Sandbox fixtures. Execution is reserved for branch
  review as the prepared step requires.
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
  alias GtfsPlanner.Gtfs.FareProductDetail
  alias GtfsPlanner.Gtfs.Fares
  alias GtfsPlanner.Gtfs.Fares.Conversion
  alias GtfsPlanner.Repo
  alias GtfsPlanner.Support.StagedImport

  setup context do
    organization =
      organization_fixture(%{alias: "fare-rules-#{System.unique_integer([:positive])}"})

    user =
      user_fixture(%{
        email: "fare-rules-#{System.pid()}-#{System.unique_integer([:positive])}@example.com"
      })

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

  test "saving a weekday period lists it and enables the When selector", ctx do
    version = managed(ctx)
    view = open_where(ctx, version)

    view |> element("#create-time-period") |> render_click()
    assert has_element?(view, "#time-period-drawer")

    view
    |> element("#time-period-form")
    |> render_submit(%{
      "time_period" => %{
        "name" => "Weekday peak",
        "weekdays" => ["1", "2", "3", "4", "5"],
        "ranges" => %{"0" => %{"start_time" => "07:00", "end_time" => "09:00"}},
        "until_end_of_day" => "false"
      }
    })

    refute has_element?(view, "#time-period-drawer")
    assert has_element?(view, "#time-periods-list", "Weekday peak")

    view |> element("#add-fare-rule") |> render_click()
    assert has_element?(view, "#rule-drawer")
    assert view |> element("#rule-time-period") |> render() =~ "Weekday peak"
    refute has_element?(view, "#rule-time-period[disabled]")
  end

  test "a conflicting zone rule offers the current fare as an overlap choice", ctx do
    version = managed(ctx)
    view = open_where(ctx, version)

    view |> element("#add-fare-rule") |> render_click()

    view
    |> element("#rule-form")
    |> render_change(%{
      "rule" => %{
        "network_id" => "N_LOCAL",
        "from_area_id" => "TOL",
        "to_area_id" => "CST",
        "fare_product_id" => "coast_ride_adult_cash"
      }
    })

    assert has_element?(view, "#rule-overlap")
    assert has_element?(view, "#rule-overlap-replace")
    assert has_element?(view, "#rule-overlap-keep")

    view
    |> element("#rule-form")
    |> render_change(%{
      "rule" => %{
        "network_id" => "N_LOCAL",
        "from_area_id" => "TOL",
        "to_area_id" => "CST",
        "fare_product_id" => "coast_ride_adult_cash",
        "overlap" => "replace"
      }
    })

    assert has_element?(view, "#rule-overlap-replace[checked]")
    assert has_element?(view, "#save-rule", "Replace Valley-coast ride")

    view
    |> element("#rule-form")
    |> render_submit(%{
      "rule" => %{
        "network_id" => "N_LOCAL",
        "from_area_id" => "TOL",
        "to_area_id" => "CST",
        "fare_product_id" => "coast_ride_adult_cash",
        "overlap" => "replace"
      }
    })

    refute has_element?(view, "#rule-drawer")
    coast_rule = workspace_rule(ctx, version, "Coast ride")
    assert coast_rule.from_area_id == "TOL"
    assert coast_rule.to_area_id == "CST"
    refute workspace_rule(ctx, version, "Valley–coast ride")

    view |> element("#edit-fare-rule-#{coast_rule.id}") |> render_click()
    assert has_element?(view, "#delete-fare-rule")
    view |> element("#delete-fare-rule") |> render_click()

    refute workspace_rule(ctx, version, "Coast ride")
  end

  test "Show feed IDs reveals the rule's scoped GTFS fields", ctx do
    version = managed(ctx)
    view = open_where(ctx, version)
    {:ok, workspace} = Fares.load_workspace(ctx.organization.id, version.id)
    pass = Enum.find(workspace.fares, &(&1.name == "Day pass"))
    pass_rule = hd(pass.rules)

    assert has_element?(view, "#rule-list")
    view |> element("#show-rule-feed-ids") |> render_click()

    assert has_element?(view, "#fare-rules code")
    assert view |> element("#fare-rules") |> render() =~ "network_id"
    assert view |> element("#fare-rules") |> render() =~ "from_area_id"
    assert has_element?(view, "#fare-rule-#{pass_rule.id}", "Managed by Passes table")
    refute has_element?(view, "#edit-fare-rule-#{pass_rule.id}")
  end

  defp managed(ctx) do
    version =
      gtfs_version_fixture(ctx.organization.id, %{
        name: "North Coast #{System.unique_integer([:positive])}"
      })

    fixture_path = FaresFixtures.fixture_path!("north_coast_v2")

    fixture_files =
      fixture_path
      |> File.ls!()
      |> Enum.filter(&(Path.extname(&1) == ".txt"))
      |> Enum.sort()
      |> Enum.map(fn filename ->
        %{filename: filename, content: File.read!(Path.join(fixture_path, filename))}
      end)

    assert {:ok, _result} =
             StagedImport.import_files(ctx.organization.id, version.id, fixture_files)

    {:ok, plan} = Conversion.preview(ctx.organization.id, version.id)
    {:ok, _converted} = Conversion.apply(scope(ctx, version), plan.fingerprint, [])

    Repo.all(
      from(detail in FareProductDetail,
        where:
          detail.organization_id == ^ctx.organization.id and
            detail.gtfs_version_id == ^version.id
      )
    )
    |> Enum.each(fn detail ->
      base = detail.fare_product_id |> String.split("_adult_") |> hd()

      accepted =
        case base do
          "day_pass" -> ["N_LOCAL"]
          "month_pass" -> ["all_routes"]
          _ -> nil
        end

      if accepted do
        {:ok, _updated} =
          detail
          |> Ecto.Changeset.change(%{kind: "pass", accepted_network_ids: accepted})
          |> Repo.update()
      end
    end)

    version
  end

  defp open_where(ctx, version) do
    {:ok, view, _html} = live(ctx.conn, ~p"/gtfs/#{version.id}/settings/fares/where")

    view
  end

  defp workspace_rule(ctx, version, fare_name) do
    {:ok, workspace} = Fares.load_workspace(ctx.organization.id, version.id)

    fare =
      Enum.find(workspace.fares, fn fare ->
        String.replace(fare.name, "–", "-") == String.replace(fare_name, "–", "-")
      end)

    case fare && Enum.find(fare.rules, &(&1.from_area_id == "TOL" and &1.to_area_id == "CST")) do
      nil -> nil
      rule -> rule
    end
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
