defmodule GtfsPlanner.FeedPublishing.ServedRunTest do
  @moduledoc """
  `FeedPublishing.served_run_id/2` names the export run a channel currently
  serves, read only from the served attempt's frozen snapshot.

  Served run has one owner: the publication row's active attempt. These cases pin
  that the answer is nil for a non-current publication, for an absent row, and
  for another channel, and that a foreign scope is forbidden.
  """
  use GtfsPlanner.DataCase, async: false

  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.OrganizationsFixtures

  alias GtfsPlanner.FeedPublishing
  alias GtfsPlanner.FeedPublishing.{Attempt, Publication}
  alias GtfsPlanner.Repo

  describe "served_run_id/2" do
    test "returns the run a current full publication serves" do
      organization = unique_organization()
      scope = editor_scope(organization)

      publication = publication!(scope, :full, :current)
      run_id = Ecto.UUID.generate()
      attempt = attempt!(organization, publication, run_id)
      activate!(publication, attempt, :current)

      assert FeedPublishing.served_run_id(scope, :full) == {:ok, run_id}
    end

    test "a pending publication serves no run" do
      organization = unique_organization()
      scope = editor_scope(organization)

      publication = publication!(scope, :full, :pending)
      attempt = attempt!(organization, publication, Ecto.UUID.generate())
      activate!(publication, attempt, :pending)

      assert FeedPublishing.served_run_id(scope, :full) == {:ok, nil}
    end

    test "a current pathways publication is not the served full run" do
      organization = unique_organization()
      scope = editor_scope(organization)

      publication = publication!(scope, :pathways, :current)
      attempt = attempt!(organization, publication, Ecto.UUID.generate())
      activate!(publication, attempt, :current)

      assert FeedPublishing.served_run_id(scope, :full) == {:ok, nil}
    end

    test "a non-member scope is forbidden" do
      organization = unique_organization()
      publication = publication!(editor_scope(organization), :full, :current)
      attempt = attempt!(organization, publication, Ecto.UUID.generate())
      activate!(publication, attempt, :current)

      other_scope = editor_scope(unique_organization())

      assert FeedPublishing.served_run_id(
               %{organization_id: organization.id, actor_id: other_scope.actor_id},
               :full
             ) == {:error, :forbidden}
    end

    test "no publication row serves no run" do
      organization = unique_organization()
      scope = editor_scope(organization)

      assert FeedPublishing.served_run_id(scope, :full) == {:ok, nil}
    end
  end

  defp unique_organization do
    organization_fixture(%{alias: "served#{System.unique_integer([:positive])}"})
  end

  # A real editor and the server-side scope map the command receives.
  defp editor_scope(organization) do
    actor = editor_fixture(organization)

    %{organization_id: organization.id, actor_id: actor.id}
  end

  defp publication!(scope, channel, status) do
    {:ok, namespace} = FeedPublishing.claim_namespace(scope)

    Repo.insert!(%Publication{
      organization_id: scope.organization_id,
      namespace_id: namespace.id,
      channel: channel,
      status: status,
      desired_revision: 1
    })
  end

  defp attempt!(organization, publication, run_id) do
    Repo.insert!(%Attempt{
      publication_id: publication.id,
      organization_id: organization.id,
      sequence: 1,
      generation: "generation-#{System.unique_integer([:positive])}",
      desired_revision: publication.desired_revision,
      state: "pending",
      manifest_body: "{}",
      manifest_sha256: String.duplicate("a", 64),
      private_snapshot: %{"source" => %{"run_id" => run_id}}
    })
  end

  defp activate!(publication, attempt, status) do
    publication
    |> Ecto.Changeset.change(%{active_attempt_id: attempt.id, status: status})
    |> Repo.update!()
  end
end
