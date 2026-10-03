defmodule GtfsPlanner.Agents.ScopeTest do
  use GtfsPlanner.DataCase, async: true

  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Agents.Scope
  alias GtfsPlanner.Gtfs.AuditContext
  alias GtfsPlanner.Repo

  @approval_text "Extend the weekday calendar through the end of the fall term."

  describe "authorize/1" do
    test "returns :ok for an active editor membership" do
      organization = organization_fixture()
      user = user_fixture()
      organization_membership_fixture(user, organization)

      assert Scope.authorize(scope_fixture(user, organization)) == :ok
    end

    test "returns {:error, :forbidden} once the membership is deactivated" do
      organization = organization_fixture()
      user = user_fixture()
      membership = organization_membership_fixture(user, organization)
      scope = scope_fixture(user, organization)

      assert Scope.authorize(scope) == :ok

      deactivate_membership_fixture(membership)

      assert Scope.authorize(scope) == {:error, :forbidden}
    end

    test "returns {:error, :forbidden} when the membership lacks the editor role" do
      organization = organization_fixture()
      user = user_fixture()
      organization_membership_fixture(user, organization, ["pathways_studio_admin"])

      assert Scope.authorize(scope_fixture(user, organization)) == {:error, :forbidden}
    end

    test "returns {:error, :forbidden} for a user with no membership in the organization" do
      organization = organization_fixture()
      user = user_fixture()

      assert Scope.authorize(scope_fixture(user, organization)) == {:error, :forbidden}
    end

    test "returns {:error, :forbidden} for an editor of another organization" do
      organization = organization_fixture()
      other_organization = organization_fixture()
      user = user_fixture()
      organization_membership_fixture(user, other_organization)

      assert Scope.authorize(scope_fixture(user, organization)) == {:error, :forbidden}
    end

    test "returns {:error, :forbidden} for a non-UUID user_id without raising" do
      organization = organization_fixture()
      user = user_fixture()
      organization_membership_fixture(user, organization)

      scope = %{scope_fixture(user, organization) | user_id: "not-a-uuid"}

      assert Scope.authorize(scope) == {:error, :forbidden}
    end
  end

  describe "the optional subject" do
    test "a scope built without a subject has a nil subject_id and authorizes as before" do
      organization = organization_fixture()
      user = user_fixture()
      organization_membership_fixture(user, organization)

      scope = scope_fixture(user, organization)

      assert scope.subject_id == nil
      assert Scope.authorize(scope) == :ok

      with_subject = %{scope | subject_id: Ecto.UUID.generate()}

      assert Scope.authorize(with_subject) == :ok
    end
  end

  describe "audit_context/1" do
    test "carries the actor identity and leaves the station unset" do
      organization = organization_fixture()
      user = user_fixture()
      version = gtfs_version_fixture(organization.id)

      scope = %Scope{
        organization_id: organization.id,
        gtfs_version_id: version.id,
        user_id: user.id,
        user_email: user.email,
        pack_id: "calendars",
        version_name: version.name
      }

      assert %AuditContext{} = audit = Scope.audit_context(scope)

      assert audit.organization_id == organization.id
      assert audit.gtfs_version_id == version.id
      assert audit.station_stop_id == nil
      assert audit.actor_id == user.id
      assert audit.actor_email == user.email
    end
  end

  describe "the resource context" do
    test "context/1 binds one identity and leaves the approval and the source unset" do
      id = Ecto.UUID.generate()

      assert Scope.context({:route, id}) == %{
               identity: {:route, id},
               approved_extension: nil,
               source_snapshot: nil
             }
    end

    test "identity/1 reads the bound identity and is nil without one" do
      context = resources_fixture()
      route_scope = route_scope(context)

      assert Scope.identity(route_scope) == {:route, context.route.id}
      assert Scope.identity(version_scope(context)) == {:version, context.version.id}
      assert Scope.identity(context.scope) == nil
    end

    test "approved_digest/1 is stable for one approval and changes with any of its values" do
      scope = approved_scope(resources_fixture())
      digest = Scope.approved_digest(scope)

      assert byte_size(digest) == 64
      assert digest == Scope.approved_digest(scope)

      assert digest !=
               Scope.approved_digest(approved_scope(resources_fixture(), ~D[2026-11-30]))

      assert digest !=
               Scope.approved_digest(
                 approved_scope(
                   resources_fixture(),
                   ~D[2026-10-12],
                   "Extended for the school board."
                 )
               )
    end

    test "approved_digest/1 is \"none\" without an approved extension" do
      assert Scope.approved_digest(resources_fixture().scope) == "none"
    end
  end

  describe "the source snapshot seam" do
    test "an envelope that carries its own digest is refused, and a payload whose content is a digest is admitted" do
      context = resources_fixture()
      resources = Scope.context({:version, context.version.id})

      # The attack half: a caller asserting what the payload hashes to. The
      # envelope is admitted only as exactly `kind` and `payload`, so this is
      # refused rather than admitted with the caller's value overwritten.
      assert Scope.with_source_snapshot(
               resources,
               %{kind: "timetable", payload: %{"rows" => []}, digest: digest_stub()}
             ) == {:error, :invalid_snapshot}

      assert Scope.with_source_snapshot(
               resources,
               %{"kind" => "timetable", "payload" => %{"rows" => []}, "digest" => digest_stub()}
             ) == {:error, :invalid_snapshot}

      # The legitimate half: a GTFS source that carries its own content hash, as
      # a file manifest or a hash column does. It is content, it is admitted,
      # and it is kept verbatim; the envelope's digest beside it is the
      # server's own hash of `{kind, payload}` and ignores the payload's field.
      payload = %{
        "digest" => digest_stub(),
        "label" => "school",
        "rows" => [%{"source_row_id" => 1, "text" => "Mon 07:10 to Main St"}]
      }

      assert {:ok, admitted} =
               Scope.with_source_snapshot(resources, %{kind: "timetable", payload: payload})

      assert admitted.source_snapshot.payload == payload
      assert admitted.source_snapshot.digest == server_digest("timetable", payload)
      refute admitted.source_snapshot.digest == digest_stub()

      scope = %{context.scope | resource_context: admitted}

      assert Scope.source_snapshot(scope).payload["digest"] == digest_stub()
      assert Scope.authorized_context(scope) == :ok
    end

    test "a snapshot whose content was replaced after admission is refused, not read as no source" do
      context = resources_fixture()
      resources = Scope.context({:version, context.version.id})

      assert {:ok, admitted} =
               Scope.with_source_snapshot(resources, %{
                 kind: "timetable",
                 payload: %{"rows" => []}
               })

      snapshot = admitted.source_snapshot
      swapped = %{snapshot | payload: %{"rows" => [%{"text" => "someone else's table"}]}}
      tampered = %{context.scope | resource_context: %{admitted | source_snapshot: swapped}}

      # The read is unchanged — it is the boundary that refuses, and it refuses
      # as unavailable rather than degrading the tampered snapshot to `nil`.
      assert Scope.source_snapshot(tampered) == swapped
      assert Scope.authorized_context(tampered) == {:error, :unavailable}
    end

    test "context_digest/1 binds the kind and the content, and is defined without a snapshot" do
      context = resources_fixture()
      resources = Scope.context({:version, context.version.id})
      payload = %{"rows" => [%{"text" => "Mon 07:10"}]}

      assert {:ok, one} =
               Scope.with_source_snapshot(resources, %{kind: "timetable", payload: payload})

      assert {:ok, same} =
               Scope.with_source_snapshot(resources, %{kind: "timetable", payload: payload})

      assert {:ok, other_kind} =
               Scope.with_source_snapshot(resources, %{kind: "agency_note", payload: payload})

      assert {:ok, other_content} =
               Scope.with_source_snapshot(resources, %{
                 kind: "timetable",
                 payload: %{"rows" => [%{"text" => "Tue 08:25"}]}
               })

      without = %{context.scope | resource_context: resources}
      first = %{context.scope | resource_context: one}
      same = %{context.scope | resource_context: same}
      relabelled = %{context.scope | resource_context: other_kind}
      replaced = %{context.scope | resource_context: other_content}

      assert byte_size(Scope.context_digest(without)) == 64
      assert Scope.context_digest(without) != "none"
      assert Scope.context_digest(first) == Scope.context_digest(same)
      assert Scope.context_digest(first) != Scope.context_digest(without)
      assert Scope.context_digest(first) != Scope.context_digest(relabelled)
      assert Scope.context_digest(first) != Scope.context_digest(replaced)

      # The approval's own digest is untouched by any of this, so a host can
      # still reason about the approval alone.
      assert Scope.approved_digest(without) == "none"
      assert Scope.approved_digest(first) == "none"
    end
  end

  describe "authorized_context/1" do
    test "returns :ok for the scope's own version identity" do
      context = resources_fixture()

      assert Scope.authorized_context(version_scope(context)) == :ok
    end

    test "returns :ok for a route of the current organization and version" do
      context = resources_fixture()

      assert Scope.authorized_context(route_scope(context)) == :ok
    end

    test "returns the same {:error, :unavailable} for a foreign, deleted and malformed route" do
      context = resources_fixture()
      scope = route_scope(context)

      foreign = %{scope | resource_context: Scope.context({:route, context.foreign_route.id})}

      other_version = %{
        scope
        | resource_context: Scope.context({:route, context.other_version_route.id})
      }

      missing = %{scope | resource_context: Scope.context({:route, Ecto.UUID.generate()})}
      malformed = %{scope | resource_context: Scope.context({:route, "not-a-uuid"})}

      assert Scope.authorized_context(foreign) == {:error, :unavailable}
      assert Scope.authorized_context(other_version) == {:error, :unavailable}
      assert Scope.authorized_context(missing) == {:error, :unavailable}
      assert Scope.authorized_context(malformed) == {:error, :unavailable}
    end

    test "returns {:error, :unavailable} once the route is deleted" do
      context = resources_fixture()
      scope = route_scope(context)
      assert Scope.authorized_context(scope) == :ok

      Repo.delete!(context.route)

      assert Scope.authorized_context(scope) == {:error, :unavailable}
    end

    test "returns {:error, :unavailable} for a version identity that is not the scope version" do
      context = resources_fixture()
      scope = version_scope(context)

      mismatched = %{
        scope
        | resource_context: Scope.context({:version, context.other_version.id})
      }

      foreign = %{scope | resource_context: Scope.context({:version, context.foreign_version.id})}

      assert Scope.authorized_context(mismatched) == {:error, :unavailable}
      assert Scope.authorized_context(foreign) == {:error, :unavailable}
    end

    test "returns {:error, :forbidden} for a revoked editor, and stays forbidden once the route is gone" do
      context = resources_fixture()
      scope = route_scope(context)
      assert Scope.authorized_context(scope) == :ok

      deactivate_membership_fixture(context.membership)

      assert Scope.authorized_context(scope) == {:error, :forbidden}

      Repo.delete!(context.route)

      assert Scope.authorized_context(scope) == {:error, :forbidden}
    end

    test "resolves an approved extension only for a calendar of the current version" do
      context = resources_fixture()

      assert Scope.authorized_context(approved_scope(context)) == :ok

      assert Scope.authorized_context(
               approved_scope(context, ~D[2026-10-12], "Approved.", "MISSING")
             ) ==
               {:error, :unavailable}
    end

    test "returns {:error, :unavailable} for an overlong, blank or incomplete approval" do
      context = resources_fixture()

      overlong = approved_scope(context, ~D[2026-10-12], String.duplicate("a", 2_001))
      blank = approved_scope(context, ~D[2026-10-12], "   ")

      incomplete = %{
        context.scope
        | resource_context: %{
            identity: {:version, context.version.id},
            approved_extension: %{service_id: "SCHOOL_WD"}
          }
      }

      assert Scope.authorized_context(overlong) == {:error, :unavailable}
      assert Scope.authorized_context(blank) == {:error, :unavailable}
      assert Scope.authorized_context(incomplete) == {:error, :unavailable}
    end
  end

  # A well-formed 64-character lowercase digest that hashes nothing here.
  defp digest_stub, do: "a" <> String.duplicate("0", 63)

  # Lowercase SHA-256 of the server's own deterministic term encoding, written
  # out here rather than read back from the module under test.
  defp server_digest(kind, payload) do
    {kind, payload}
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp scope_fixture(user, organization) do
    version = gtfs_version_fixture(organization.id)

    %Scope{
      organization_id: organization.id,
      gtfs_version_id: version.id,
      user_id: user.id,
      user_email: user.email,
      pack_id: "calendars",
      version_name: version.name
    }
  end

  # One editor, one version, a route and a calendar of that version, and the
  # identities that must not resolve inside them.
  defp resources_fixture do
    organization = organization_fixture()
    user = user_fixture()
    membership = organization_membership_fixture(user, organization)
    version = gtfs_version_fixture(organization.id)
    route = route_fixture(organization.id, version.id)
    calendar_fixture(organization.id, version.id, %{service_id: "SCHOOL_WD"})

    other_version = gtfs_version_fixture(organization.id)
    other_version_route = route_fixture(organization.id, other_version.id)

    foreign_organization = organization_fixture()
    foreign_version = gtfs_version_fixture(foreign_organization.id)
    foreign_route = route_fixture(foreign_organization.id, foreign_version.id)

    %{
      organization: organization,
      user: user,
      membership: membership,
      version: version,
      route: route,
      other_version: other_version,
      other_version_route: other_version_route,
      foreign_version: foreign_version,
      foreign_route: foreign_route,
      scope: %Scope{
        organization_id: organization.id,
        gtfs_version_id: version.id,
        user_id: user.id,
        user_email: user.email,
        pack_id: "calendars",
        version_name: version.name
      }
    }
  end

  # The whole-version identity a Calendars page binds.
  defp version_scope(context) do
    %{context.scope | resource_context: Scope.context({:version, context.version.id})}
  end

  # The single-route identity a Route schedules page binds.
  defp route_scope(context) do
    %{context.scope | resource_context: Scope.context({:route, context.route.id})}
  end

  defp approved_scope(
         context,
         end_date \\ ~D[2026-10-12],
         approval_text \\ @approval_text,
         service_id \\ "SCHOOL_WD"
       ) do
    approved = %{service_id: service_id, end_date: end_date, approval_text: approval_text}

    %{
      context.scope
      | resource_context: %{
          identity: {:version, context.version.id},
          approved_extension: approved
        }
    }
  end
end
