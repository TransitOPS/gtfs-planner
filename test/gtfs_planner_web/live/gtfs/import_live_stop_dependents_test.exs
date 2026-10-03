defmodule GtfsPlannerWeb.Gtfs.ImportLiveStopDependentsTest do
  @moduledoc """
  The import review's removal row tells the reviewer what still uses a stop. The
  kinds it names now come from the one shared reference list, so the sentence has
  to keep its old wording for the kinds it already showed and gain a noun for
  every kind the shared list adds.

  A kind with no noun raises inside `ngettext`, which would take down the whole
  review screen rather than one row. That is the risk these cases cover: each new
  kind gets a row here, so a kind added to the list without a noun fails here.
  """

  use GtfsPlannerWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Gtfs.DeadheadTime
  alias GtfsPlanner.Gtfs.FlexService
  alias GtfsPlanner.Gtfs.Import.{ChangeDecision, ChangeRun}
  alias GtfsPlanner.Gtfs.ReliefPoint
  alias GtfsPlanner.Gtfs.StopArea
  alias GtfsPlanner.Gtfs.Translation
  alias GtfsPlanner.Repo

  setup %{conn: conn} do
    organization = organization_fixture()
    user = user_fixture()
    version = gtfs_version_fixture(organization.id)

    Accounts.create_user_org_membership(%{
      user_id: user.id,
      organization_id: organization.id,
      roles: ["pathways_studio_editor"]
    })

    conn = log_in_user(conn, user, organization: organization)
    {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/import")

    %{
      conn: conn,
      view: view,
      organization: organization,
      version: version,
      ctx: %{organization: organization, version: version}
    }
  end

  test "a removal of a stop with a relief point names it", context do
    %{view: view, decision_id: decision_id} =
      review_removal(context, "1434", fn ctx ->
        Repo.insert!(%ReliefPoint{
          organization_id: ctx.organization.id,
          gtfs_version_id: ctx.version.id,
          stop_id: "1434"
        })
      end)

    assert has_element?(
             view,
             "#diff-decision-dependents-#{decision_id}",
             "Used by 1 relief point. Removal will be refused while they exist."
           )
  end

  test "a removal of a stop with a flex hub names it", context do
    %{view: view, decision_id: decision_id} =
      review_removal(context, "1434", fn ctx ->
        Repo.insert!(%FlexService{
          organization_id: ctx.organization.id,
          gtfs_version_id: ctx.version.id,
          key: "FLEX1",
          name: "Downtown flex",
          kind: :area,
          hub_stop_ids: ["1434"]
        })
      end)

    assert has_element?(view, "#diff-decision-dependents-#{decision_id}", "1 flex hub service")
  end

  test "a removal of a stop with a deadhead time to it names it", context do
    %{view: view, decision_id: decision_id} =
      review_removal(context, "1434", fn ctx ->
        Repo.insert!(%DeadheadTime{
          organization_id: ctx.organization.id,
          gtfs_version_id: ctx.version.id,
          from_ref: "garage:#{Ecto.UUID.generate()}",
          to_ref: "stop:1434",
          minutes: 12
        })
      end)

    assert has_element?(
             view,
             "#diff-decision-dependents-#{decision_id}",
             "1 deadhead time to this stop"
           )
  end

  test "a removal of a stop with a stop area, a translation and a flex endpoint names all three",
       context do
    %{view: view, decision_id: decision_id} =
      review_removal(context, "1434", fn ctx ->
        org = ctx.organization.id
        version = ctx.version.id

        Repo.insert!(%StopArea{
          organization_id: org,
          gtfs_version_id: version,
          area_id: "AREA1",
          stop_id: "1434"
        })

        Repo.insert!(%Translation{
          organization_id: org,
          gtfs_version_id: version,
          table_name: "stops",
          record_id: "1434",
          field_name: "stop_name",
          language: "es",
          translation: "Southwest 1st"
        })

        Repo.insert!(%FlexService{
          organization_id: org,
          gtfs_version_id: version,
          key: "FLEX2",
          name: "Airport flex",
          kind: :area,
          first_stop_id: "1434"
        })
      end)

    assert has_element?(
             view,
             "#diff-decision-dependents-#{decision_id}",
             "stop area"
           )

    assert has_element?(
             view,
             "#diff-decision-dependents-#{decision_id}",
             "translation"
           )

    assert has_element?(
             view,
             "#diff-decision-dependents-#{decision_id}",
             "flex service first stop"
           )
  end

  test "a stop with a floorplan is listed, because the floorplan names the stop by its GTFS ID",
       context do
    # `stop_levels.stop_id` stores the station's scoped GTFS identifier, so the
    # review can count it by the natural key it is removing. `journal_entries`
    # remains a `via: :fk_uuid` reference with no `stops.id` to match, which is
    # why `StopEditing.delete_review/2` refuses a delete on a journal entry
    # rather than relying on a count from here.
    %{view: view, decision_id: decision_id} =
      review_removal(context, "1434", fn ctx ->
        stop = Repo.get_by!(GtfsPlanner.Gtfs.Stop, stop_id: "1434")

        level =
          level_fixture(ctx.organization.id, ctx.version.id, %{level_id: "L1"})

        GtfsPlanner.GtfsFixtures.insert_stop_level(%{
          organization_id: ctx.organization.id,
          gtfs_version_id: ctx.version.id,
          stop_id: stop.stop_id,
          level_id: level.level_id
        })
      end)

    assert has_element?(view, "#diff-decision-dependents-#{decision_id}")

    assert view |> element("#diff-decision-dependents-#{decision_id}") |> render() =~
             "1 level"
  end

  test "a removal of a stop nothing uses omits the line", context do
    %{view: view, decision_id: decision_id} = review_removal(context, "1434", fn _ctx -> :ok end)

    refute has_element?(view, "#diff-decision-dependents-#{decision_id}")
  end

  # The dependents are computed when the view mounts, so a test inserts the rows
  # that block the removal, then opens the review.
  defp review_removal(context, stop_id, setup) do
    stop_fixture(context.organization.id, context.version.id, %{stop_id: stop_id})

    setup.(context)

    run = insert_run!(context.organization, context.version)
    decision = insert_removal!(run, stop_id)

    {:ok, view, _html} = live(context.conn, "/gtfs/#{context.version.id}/import")
    %{view: view, decision_id: decision.id}
  end

  defp insert_run!(organization, version) do
    now = DateTime.utc_now()

    %ChangeRun{}
    |> ChangeRun.system_changeset(%{
      organization_id: organization.id,
      gtfs_version_id: version.id,
      actor_id: Ecto.UUID.generate(),
      actor_email: "reviewer@example.com",
      state: :review,
      phase: :cleanup,
      summary: %{"applied" => 0, "failed" => 0, "unapplied" => 1},
      started_at: now,
      finished_at: nil
    })
    |> Repo.insert!()
  end

  defp insert_removal!(run, key) do
    %ChangeDecision{}
    |> ChangeDecision.system_changeset(%{
      change_run_id: run.id,
      decision_id: "stop:#{key}",
      entity_type: :stop,
      action: :remove,
      status: :pending,
      natural_key: key,
      apply_failure_code: nil
    })
    |> Repo.insert!()
  end
end
