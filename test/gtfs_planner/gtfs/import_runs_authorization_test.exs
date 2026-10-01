defmodule GtfsPlanner.Gtfs.ImportRunsAuthorizationTest do
  @moduledoc """
  EV-38 (CL-3, FH-8): user-originated import and change-run transitions reauthorize their actor
  inside the transaction, and a full import publishes only for a run actor who still holds an
  active editor membership.

  Publication runs through the real `Publication` module with a small fixture feed. A deactivated
  or non-editor user is refused with `{:error, :forbidden}` and every run, version and review row
  stays as it was. Rows are created in the SQL sandbox and rolled back with it.
  """

  use GtfsPlanner.DataCase, async: false

  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.Import.{ChangeRun, ChangeRuns, Failure, Publication, Result, Run}
  alias GtfsPlanner.Gtfs.ImportRuns
  alias GtfsPlanner.Repo
  alias GtfsPlanner.Versions
  alias GtfsPlanner.Versions.GtfsVersion

  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  @levels_content "level_id,level_index,level_name\nL1,0.0,Ground Floor\n"

  @result %Result{
    counts: %{levels: 1},
    unrecognized_files: [],
    topic: "import:authorization",
    archive_warnings: [],
    extensions: :not_present
  }

  # An editor with the membership row a test can revoke.
  defp editor(organization) do
    user = user_fixture()
    membership = organization_membership_fixture(user, organization)
    %{membership: membership, actor: %{id: user.id, email: user.email}}
  end

  defp revoke!(%{membership: membership}), do: deactivate_membership_fixture(membership)

  defp claimed_import(organization, actor) do
    {:ok, %{run: run}} =
      ImportRuns.create_pending_target(organization.id, actor, %{name: "Authorized feed"})

    {:ok, claimed, _version, token} =
      ImportRuns.claim_import(organization.id, run.id, run.lease_token)

    {claimed, token}
  end

  defp publication_failed_run(organization, actor) do
    {run, token} = claimed_import(organization, actor)

    {:ok, _failed} =
      ImportRuns.record_publication_failure(
        organization.id,
        run.id,
        token,
        @result,
        :database_error
      )

    run
  end

  defp failed_run(organization, actor) do
    {run, token} = claimed_import(organization, actor)

    failure = Failure.from_error(:unknown, phase: :phase_2, outcome: :failed)

    {:ok, _failed_run, _version} = ImportRuns.fail_import(organization.id, run.id, token, failure)
    run
  end

  defp import_row_counts(organization) do
    %{
      runs: Repo.aggregate(from(r in Run, where: r.organization_id == ^organization.id), :count),
      versions:
        Repo.aggregate(
          from(v in GtfsVersion, where: v.organization_id == ^organization.id),
          :count
        )
    }
  end

  describe "publication" do
    test "an actor deactivated before publication leaves the version unpublished and the run publication_failed" do
      organization = organization_fixture()
      editor = editor(organization)
      {run, token} = claimed_import(organization, editor.actor)
      revoke!(editor)

      files = [%{filename: "levels.txt", content: @levels_content}]

      assert {:error, %GtfsVersion{publication_status: "importing"},
              {:publication_failed, :forbidden}} =
               Publication.run(run, token, files, "import:authorization-revoked")

      refute Versions.published_gtfs_version_for_org?(organization.id, run.gtfs_version_id)

      failed = Repo.get!(Run, run.id)
      assert failed.state == "publication_failed"
      assert failed.reason_code == "forbidden"
      assert failed.counts_complete == true
      assert is_nil(failed.lease_token)

      # The imported rows stay staged in the unpublished version.
      assert length(Gtfs.list_levels(organization.id, run.gtfs_version_id)) == 1
    end

    test "a run refused for its actor is published by another active editor" do
      organization = organization_fixture()
      editor = editor(organization)
      successor = editor(organization)
      {run, token} = claimed_import(organization, editor.actor)
      revoke!(editor)

      files = [%{filename: "levels.txt", content: @levels_content}]

      assert {:error, _version, {:publication_failed, :forbidden}} =
               Publication.run(run, token, files, "import:authorization-successor")

      assert {:ok, %Run{state: "published"}, %GtfsVersion{publication_status: "published"}} =
               ImportRuns.retry_publication(organization.id, run.id, successor.actor)

      assert Versions.published_gtfs_version_for_org?(organization.id, run.gtfs_version_id)
    end

    test "a run whose actor is still an editor publishes" do
      organization = organization_fixture()
      editor = editor(organization)
      {run, token} = claimed_import(organization, editor.actor)

      files = [%{filename: "levels.txt", content: @levels_content}]

      assert {:ok, %GtfsVersion{publication_status: "published"}, _result} =
               Publication.run(run, token, files, "import:authorization-active")

      assert Repo.get!(Run, run.id).state == "published"
    end
  end

  describe "retry_publication/3" do
    setup do
      organization = organization_fixture()
      owner = editor(organization)
      run = publication_failed_run(organization, owner.actor)
      %{organization: organization, run: run}
    end

    test "refuses a deactivated user and leaves the run and version unchanged", %{
      organization: organization,
      run: run
    } do
      deactivated = editor(organization)
      revoke!(deactivated)

      assert {:error, :forbidden} =
               ImportRuns.retry_publication(organization.id, run.id, deactivated.actor)

      assert Repo.get!(Run, run.id).state == "publication_failed"
      assert Repo.get!(GtfsVersion, run.gtfs_version_id).publication_status == "importing"
    end

    test "refuses an active member who is not an editor", %{organization: organization, run: run} do
      user = user_fixture()
      organization_membership_fixture(user, organization, ["pathways_studio_admin"])

      assert {:error, :forbidden} =
               ImportRuns.retry_publication(organization.id, run.id, %{
                 id: user.id,
                 email: user.email
               })

      assert Repo.get!(Run, run.id).state == "publication_failed"
      assert Repo.get!(GtfsVersion, run.gtfs_version_id).publication_status == "importing"
    end

    test "refuses an editor of another organization", %{organization: organization, run: run} do
      outsider = editor(organization_fixture())

      assert {:error, :forbidden} =
               ImportRuns.retry_publication(organization.id, run.id, outsider.actor)

      assert Repo.get!(GtfsVersion, run.gtfs_version_id).publication_status == "importing"
    end

    test "publishes for an active editor", %{organization: organization, run: run} do
      retrier = editor(organization)

      assert {:ok, %Run{state: "published"}, %GtfsVersion{publication_status: "published"}} =
               ImportRuns.retry_publication(organization.id, run.id, retrier.actor)
    end
  end

  describe "create_pending_target/3" do
    test "refuses a deactivated user and creates no run or version" do
      organization = organization_fixture()
      editor = editor(organization)
      revoke!(editor)
      before_counts = import_row_counts(organization)

      assert {:error, :forbidden} =
               ImportRuns.create_pending_target(organization.id, editor.actor, %{name: "Refused"})

      assert import_row_counts(organization) == before_counts
    end

    test "refuses an actor with no membership in the organization" do
      organization = organization_fixture()
      outsider = editor(organization_fixture())
      before_counts = import_row_counts(organization)

      assert {:error, :forbidden} =
               ImportRuns.create_pending_target(organization.id, outsider.actor, %{
                 name: "Refused"
               })

      assert import_row_counts(organization) == before_counts
    end
  end

  describe "claim_cleanup/3" do
    test "refuses a deactivated user and leaves the failed run claimable by an editor" do
      organization = organization_fixture()
      owner = editor(organization)
      run = failed_run(organization, owner.actor)
      deactivated = editor(organization)
      revoke!(deactivated)

      assert {:error, :forbidden} =
               ImportRuns.claim_cleanup(organization.id, run.id, deactivated.actor)

      unclaimed = Repo.get!(Run, run.id)
      assert unclaimed.state == "failed"
      assert is_nil(unclaimed.lease_token)
      assert is_nil(unclaimed.cleanup_actor_id)

      assert {:ok, %Run{state: "cleaning"}, _version, _token} =
               ImportRuns.claim_cleanup(organization.id, run.id, owner.actor)
    end

    test "refuses a deactivated user before reporting an already claimed run" do
      organization = organization_fixture()
      owner = editor(organization)
      run = failed_run(organization, owner.actor)

      {:ok, _cleaning, _version, _token} =
        ImportRuns.claim_cleanup(organization.id, run.id, owner.actor)

      deactivated = editor(organization)
      revoke!(deactivated)

      assert {:error, :forbidden} =
               ImportRuns.claim_cleanup(organization.id, run.id, deactivated.actor)
    end
  end

  describe "change run requests by a deactivated user" do
    setup do
      organization = organization_fixture()
      version = gtfs_version_fixture(organization.id)
      %{organization: organization, version: version, owner: editor(organization)}
    end

    test "create_pending_compute creates no run", %{
      organization: organization,
      version: version
    } do
      deactivated = editor(organization)
      revoke!(deactivated)

      assert {:error, :forbidden} =
               ChangeRuns.create_pending_compute(
                 organization.id,
                 version.id,
                 deactivated.actor,
                 []
               )

      assert change_run_count(organization) == 0
    end

    test "create_pending_compute does not return another user's active run", %{
      organization: organization,
      version: version,
      owner: owner
    } do
      {:ok, active} =
        ChangeRuns.create_pending_compute(organization.id, version.id, owner.actor, [])

      deactivated = editor(organization)
      revoke!(deactivated)

      assert {:error, :forbidden} =
               ChangeRuns.create_pending_compute(
                 organization.id,
                 version.id,
                 deactivated.actor,
                 []
               )

      assert change_run_count(organization) == 1
      assert Repo.get!(ChangeRun, active.id).state == :pending_compute
    end

    test "request_apply leaves the review unchanged", %{
      organization: organization,
      version: version,
      owner: owner
    } do
      review = review_run!(organization, version, owner.actor)
      deactivated = editor(organization)
      revoke!(deactivated)

      assert {:error, :forbidden} =
               ChangeRuns.request_apply(organization.id, review.id, deactivated.actor)

      unchanged = Repo.get!(ChangeRun, review.id)
      assert unchanged.state == :review
      assert unchanged.actor_id == owner.actor.id
    end

    test "request_cancel leaves the pending run uncancelled", %{
      organization: organization,
      version: version,
      owner: owner
    } do
      {:ok, run} = ChangeRuns.create_pending_compute(organization.id, version.id, owner.actor, [])
      deactivated = editor(organization)
      revoke!(deactivated)

      assert {:error, :forbidden} =
               ChangeRuns.request_cancel(organization.id, run.id, deactivated.actor)

      unchanged = Repo.get!(ChangeRun, run.id)
      assert unchanged.state == :pending_compute
      assert is_nil(unchanged.cancel_requested_at)
    end

    test "retry leaves the failed run failed", %{
      organization: organization,
      version: version,
      owner: owner
    } do
      run = failed_compute_run!(organization, version, owner.actor)
      deactivated = editor(organization)
      revoke!(deactivated)

      assert {:error, :forbidden} = ChangeRuns.retry(organization.id, run.id, deactivated.actor)

      assert Repo.get!(ChangeRun, run.id).state == :failed
    end

    test "start_over leaves the failed run as it was", %{
      organization: organization,
      version: version,
      owner: owner
    } do
      run = failed_compute_run!(organization, version, owner.actor)
      deactivated = editor(organization)
      revoke!(deactivated)

      assert {:error, :forbidden} =
               ChangeRuns.start_over(organization.id, run.id, deactivated.actor)

      unchanged = Repo.get!(ChangeRun, run.id)
      assert unchanged.state == :failed
      assert unchanged.failure_code == "compute_failed"
    end
  end

  describe "the run's actor after a request" do
    setup do
      organization = organization_fixture()
      version = gtfs_version_fixture(organization.id)
      %{organization: organization, version: version, owner: editor(organization)}
    end

    test "request_apply by another active editor makes that editor the run's actor", %{
      organization: organization,
      version: version,
      owner: owner
    } do
      review = review_run!(organization, version, owner.actor)
      revoke!(owner)
      successor = editor(organization)

      assert {:ok, %ChangeRun{state: :pending_apply} = pending} =
               ChangeRuns.request_apply(organization.id, review.id, successor.actor)

      assert pending.actor_id == successor.actor.id
      assert pending.actor_email == successor.actor.email
    end

    test "retry of a partial run by another active editor makes that editor the run's actor", %{
      organization: organization,
      version: version,
      owner: owner
    } do
      partial = partial_run!(organization, version, owner.actor)
      revoke!(owner)
      successor = editor(organization)

      assert {:ok, %ChangeRun{state: :pending_apply} = pending} =
               ChangeRuns.retry(organization.id, partial.id, successor.actor)

      assert pending.actor_id == successor.actor.id
      assert pending.actor_email == successor.actor.email
    end
  end

  defp change_run_count(organization) do
    Repo.aggregate(from(r in ChangeRun, where: r.organization_id == ^organization.id), :count)
  end

  defp review_run!(organization, version, actor) do
    {:ok, run} = ChangeRuns.create_pending_compute(organization.id, version.id, actor, [])
    {:ok, _computing, generation, token} = ChangeRuns.claim(organization.id, run.id, :compute)

    {:ok, review} =
      ChangeRuns.persist_review(organization.id, run.id, generation, token, %{
        decisions: [
          %{
            serializer_version: 1,
            decision_id: "level:L2",
            entity_type: :level,
            action: :add,
            status: :pending,
            natural_key: "L2",
            current_values: %{},
            uploaded_values: %{level_index: 2.0},
            changed_fields: [],
            dependency_keys: [],
            current_fingerprint: nil,
            user_edited: false
          }
        ],
        summary: %{applicable: 1, add: 1},
        diagnostics: []
      })

    review
  end

  defp failed_compute_run!(organization, version, actor) do
    {:ok, run} = ChangeRuns.create_pending_compute(organization.id, version.id, actor, [])
    {:ok, _computing, generation, token} = ChangeRuns.claim(organization.id, run.id, :compute)

    {:ok, failed} =
      ChangeRuns.fail_compute(organization.id, run.id, generation, token, "compute_failed")

    failed
  end

  # A run an earlier apply left partial, as the change worker closes one.
  defp partial_run!(organization, version, actor) do
    now = DateTime.utc_now()

    %ChangeRun{}
    |> ChangeRun.system_changeset(%{
      organization_id: organization.id,
      gtfs_version_id: version.id,
      state: :partial,
      phase: :cleanup,
      started_at: now,
      finished_at: now,
      failure_code: "forbidden",
      actor_id: actor.id,
      actor_email: actor.email
    })
    |> Repo.insert!()
  end
end
