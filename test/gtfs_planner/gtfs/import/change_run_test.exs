defmodule GtfsPlanner.Gtfs.Import.ChangeRunTest do
  use GtfsPlanner.DataCase, async: true

  alias GtfsPlanner.Gtfs.Import.{ChangeDecision, ChangeRun}
  alias GtfsPlanner.OrganizationsFixtures
  alias GtfsPlanner.VersionsFixtures

  describe "system-owned changesets" do
    setup do
      organization = OrganizationsFixtures.organization_fixture()
      version = VersionsFixtures.gtfs_version_fixture(organization.id)

      %{run: %ChangeRun{organization_id: organization.id, gtfs_version_id: version.id}}
    end

    test "does not cast scope, actor, lease, or lifecycle fields from public params", %{run: run} do
      changeset =
        ChangeRun.changeset(run, %{
          organization_id: Ecto.UUID.generate(),
          gtfs_version_id: Ecto.UUID.generate(),
          actor_id: Ecto.UUID.generate(),
          lease_token: Ecto.UUID.generate(),
          state: :computing,
          progress_current: 9,
          summary: %{arbitrary: "value"}
        })

      assert changeset.valid?
      assert changeset.changes == %{}
    end

    test "system changeset rejects unbounded JSON and invalid progress", %{run: run} do
      changeset =
        ChangeRun.system_changeset(run, %{
          summary: %{arbitrary: "value"},
          diagnostics: [%{code: "parse_failed", detail: String.duplicate("x", 4_097)}],
          progress_current: 2,
          progress_total: 1
        })

      refute changeset.valid?
      assert errors_on(changeset).summary
      assert errors_on(changeset).diagnostics
      assert errors_on(changeset).progress_current
    end

    test "decision public changeset cannot cast run identity or application lifecycle", %{
      run: run
    } do
      decision = %ChangeDecision{change_run_id: run.id || Ecto.UUID.generate()}

      changeset =
        ChangeDecision.changeset(decision, %{
          change_run_id: Ecto.UUID.generate(),
          decision_id: "stop:central",
          status: :applied,
          applied_at: DateTime.utc_now(),
          current_values: %{"file_body" => "not allowed"}
        })

      assert changeset.valid?
      assert changeset.changes == %{}
    end
  end
end
