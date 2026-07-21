defmodule GtfsPlanner.Gtfs.Import.ChangeRunsTest do
  use GtfsPlanner.DataCase, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias GtfsPlanner.Gtfs.Import.ChangeDecision
  alias GtfsPlanner.Gtfs.Import.ChangeRun
  alias GtfsPlanner.Gtfs.Import.ChangeRuns
  alias GtfsPlanner.Repo

  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  @actor %{id: Ecto.UUID.generate(), email: "reviewer@example.com"}

  defp review_payload do
    %{
      decisions: [
        %{
          serializer_version: 1,
          decision_id: "stop:central",
          entity_type: :stop,
          action: :modify,
          status: :pending,
          natural_key: "central",
          current_values: %{"stop_name" => "Central"},
          uploaded_values: %{"stop_name" => "Central Station"},
          changed_fields: [
            %{"field" => "stop_name", "before" => "Central", "after" => "Central Station"}
          ],
          dependency_keys: ["level:L1"],
          current_fingerprint: String.duplicate("a", 64),
          user_edited: false
        }
      ],
      summary: %{applicable: 1, modify: 1},
      diagnostics: []
    }
  end

  defp expire!(run) do
    from(r in ChangeRun, where: r.id == ^run.id)
    |> Repo.update_all(set: [lease_expires_at: ~U[2000-01-01 00:00:00.000000Z]])

    Repo.get!(ChangeRun, run.id)
  end

  describe "durable compute and review transitions" do
    test "creates one scoped run, persists decisions, broadcasts after commit, and reconstructs review" do
      organization = organization_fixture()
      version = gtfs_version_fixture(organization.id)

      assert {:ok, run} =
               ChangeRuns.create_pending_compute(organization.id, version.id, @actor, [
                 %{name: "stops.txt", size: 10, sha256: String.duplicate("a", 64)}
               ])

      run_id = run.id
      assert run.state == :pending_compute
      assert run.organization_id == organization.id
      assert run.gtfs_version_id == version.id

      assert {:ok, same_run} =
               ChangeRuns.create_pending_compute(organization.id, version.id, @actor, [])

      assert same_run.id == run.id

      assert {:ok, computing, generation, token} =
               ChangeRuns.claim(organization.id, run.id, :compute)

      assert computing.state == :computing
      assert generation == 1

      Phoenix.PubSub.subscribe(GtfsPlanner.PubSub, ChangeRuns.topic(run.id))

      assert {:ok, review} =
               ChangeRuns.persist_review(
                 organization.id,
                 run.id,
                 generation,
                 token,
                 review_payload()
               )

      assert review.state == :review
      assert_receive {:change_run_changed, ^run_id}

      assert %ChangeRun{id: ^run_id, state: :review} =
               ChangeRuns.get_for_version(organization.id, version.id, run.id)

      assert [%ChangeDecision{decision_id: "stop:central", status: :pending}] =
               ChangeRuns.list_decisions(organization.id, run.id, status: :pending)

      assert {:ok, %ChangeDecision{status: :approved}} =
               ChangeRuns.set_decision_status(organization.id, run.id, "stop:central", :approved)

      assert {:ok, %ChangeRun{state: :pending_apply}} =
               ChangeRuns.request_apply(organization.id, run.id)
    end

    test "fences stale generation and token after a database-time reclaim" do
      organization = organization_fixture()
      version = gtfs_version_fixture(organization.id)
      {:ok, run} = ChangeRuns.create_pending_compute(organization.id, version.id, @actor, [])

      {:ok, claimed, first_generation, first_token} =
        ChangeRuns.claim(organization.id, run.id, :compute)

      expire!(claimed)

      assert {:ok, reclaimed, second_generation, second_token} =
               ChangeRuns.claim(organization.id, run.id, :compute)

      assert second_generation == first_generation + 1
      assert second_token != first_token
      assert reclaimed.lease_generation == second_generation

      assert {:error, :lease_lost} =
               ChangeRuns.renew_lease(organization.id, run.id, first_generation, first_token)

      assert {:error, :lease_lost} =
               ChangeRuns.persist_review(
                 organization.id,
                 run.id,
                 first_generation,
                 first_token,
                 review_payload()
               )

      assert Repo.get!(ChangeRun, run.id).state == :computing
      assert ChangeRuns.reconcile_expired(organization.id) == 0
    end
  end

  describe "scope, cancellation, retry, and reconciliation" do
    test "concurrent starts serialize on the scoped database lock" do
      organization = organization_fixture()
      version = gtfs_version_fixture(organization.id)
      parent = self()

      start_run = fn ->
        Sandbox.allow(Repo, parent, self())
        ChangeRuns.create_pending_compute(organization.id, version.id, @actor, [])
      end

      first = Task.async(start_run)
      second = Task.async(start_run)
      first_ref = Process.monitor(first.pid)
      second_ref = Process.monitor(second.pid)

      results = Task.await_many([first, second], 5_000)
      assert Enum.all?(results, &match?({:ok, _}, &1))
      assert [{:ok, first_run}, {:ok, second_run}] = results
      assert first_run.id == second_run.id
      assert_receive {:DOWN, ^first_ref, :process, _, :normal}
      assert_receive {:DOWN, ^second_ref, :process, _, :normal}
    end

    test "fails closed for foreign, duplicate, stale, cancellation, retry, and reconciliation transitions" do
      organization = organization_fixture()
      other_organization = organization_fixture()
      version = gtfs_version_fixture(organization.id)
      foreign_version = gtfs_version_fixture(other_organization.id)
      {:ok, run} = ChangeRuns.create_pending_compute(organization.id, version.id, @actor, [])

      assert {:error, :not_found} =
               ChangeRuns.create_pending_compute(organization.id, foreign_version.id, @actor, [])

      assert {:error, :not_found} = ChangeRuns.claim(other_organization.id, run.id, :compute)
      assert {:error, :invalid_transition} = ChangeRuns.retry(organization.id, run.id)

      assert {:ok, computing, generation, token} =
               ChangeRuns.claim(organization.id, run.id, :compute)

      assert {:ok, cancelling} = ChangeRuns.request_cancel(organization.id, run.id)
      assert cancelling.cancel_requested_at
      assert {:error, :invalid_transition} = ChangeRuns.request_cancel(organization.id, run.id)

      assert {:error, :lease_lost} =
               ChangeRuns.renew_lease(organization.id, run.id, generation, token)

      expired = expire!(computing)
      assert ChangeRuns.reconcile_expired(organization.id) == 1
      assert Repo.get!(ChangeRun, expired.id).state == :cancelled
      assert {:ok, retry_run} = ChangeRuns.retry(organization.id, run.id)
      assert retry_run.id != run.id
      assert {:error, :invalid_transition} = ChangeRuns.retry(organization.id, run.id)
      assert {:error, :not_found} = ChangeRuns.request_cancel(other_organization.id, run.id)
    end
  end
end
