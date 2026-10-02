defmodule GtfsPlannerWeb.Gtfs.FareEditorTransfersTest do
  @moduledoc """
  Merge evidence (EV-38) for the transfer matrix, R6 refusal and empty state.
  These cases are written for branch review and are not run during step 39.
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
  alias GtfsPlanner.Gtfs.FareTransferRule
  alias GtfsPlanner.Gtfs.Fares
  alias GtfsPlanner.Gtfs.Fares.Conversion
  alias GtfsPlanner.Gtfs.Fares.Transfers
  alias GtfsPlanner.Repo
  alias GtfsPlanner.Support.StagedImport

  setup context do
    organization =
      organization_fixture(%{alias: "fare-transfers-#{System.unique_integer([:positive])}"})

    user =
      user_fixture(%{
        email: "fare-transfers-#{System.pid()}-#{System.unique_integer([:positive])}@example.com"
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

  test "difference is disabled when the pair fails R6", ctx do
    version = managed(ctx)
    view = open_transfers(ctx, version)

    view
    |> element("#transfer-matrix button[phx-value-from='N_INTERCITY'][phx-value-to='N_LOCAL']")
    |> render_click()

    assert has_element?(view, "#transfer-drawer")
    assert has_element?(view, "#transfer-pay-difference[disabled]")
    assert has_element?(view, "#transfer-difference-reason")
  end

  test "cross-group drawer has no number-of-changes control", ctx do
    version = managed(ctx)
    view = open_transfers(ctx, version)

    view
    |> element("#transfer-matrix button[phx-value-from='N_LOCAL'][phx-value-to='N_INTERCITY']")
    |> render_click()

    assert has_element?(view, "#transfer-drawer")
    refute has_element?(view, "#transfer-form select[name='transfer[count]']")
  end

  test "saving an expressible difference reaches the scoped transfer writer", ctx do
    version = managed(ctx)
    view = open_transfers(ctx, version)

    view
    |> element("#transfer-matrix button[phx-value-from='N_LOCAL'][phx-value-to='N_INTERCITY']")
    |> render_click()

    view
    |> element("#transfer-form")
    |> render_submit(%{"transfer" => %{"pay" => "difference", "minutes" => "75"}})

    refute has_element?(view, "#transfer-drawer")
    {:ok, workspace} = Fares.load_workspace(ctx.organization.id, version.id)

    assert Enum.any?(workspace.transfers, fn transfer ->
             (transfer.from_leg_group_id == "N_LOCAL" and
                transfer.to_leg_group_id == "N_INTERCITY" and
                transfer.policy) && transfer.policy.pay == :difference
           end)
  end

  test "empty transfers offers one primary action", ctx do
    version = managed(ctx)
    {:ok, transfers} = transfers_for(ctx, version)

    Enum.each(transfers, fn transfer ->
      assert {:ok, _} =
               Transfers.save(
                 scope(ctx, version),
                 transfer.from_leg_group_id,
                 transfer.to_leg_group_id,
                 %{pay: :full, minutes: 0},
                 nil
               )
    end)

    view = open_transfers(ctx, version)
    assert has_element?(view, "#transfers-empty")
    assert has_element?(view, "#add-first-transfer-rule")
    refute has_element?(view, "#add-transfer-rule")
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

    assert {:ok, _} = StagedImport.import_files(ctx.organization.id, version.id, fixture_files)
    {:ok, plan} = Conversion.preview(ctx.organization.id, version.id)
    assert {:ok, _} = Conversion.apply(scope(ctx, version), plan.fingerprint, [])

    Repo.all(
      from detail in FareProductDetail,
        where:
          detail.organization_id == ^ctx.organization.id and detail.gtfs_version_id == ^version.id
    )
    |> Enum.each(fn detail ->
      base = detail.fare_product_id |> String.split("_adult_") |> hd()

      accepted =
        case base do
          "day_pass" -> ["N_LOCAL"]
          "month_pass" -> ["all_routes"]
          _ -> nil
        end

      if accepted,
        do:
          Repo.update!(
            Ecto.Changeset.change(detail, %{kind: "pass", accepted_network_ids: accepted})
          )
    end)

    version
  end

  defp transfers_for(ctx, version) do
    rules =
      Repo.all(
        from rule in FareTransferRule,
          where:
            rule.organization_id == ^ctx.organization.id and rule.gtfs_version_id == ^version.id
      )

    {:ok, rules}
  end

  defp open_transfers(ctx, version) do
    {:ok, view, _html} = live(ctx.conn, ~p"/gtfs/#{version.id}/settings/fares/transfers")
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
