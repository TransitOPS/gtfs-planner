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
    test "context/1 binds one identity and leaves the approved extension unset" do
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

    test "context_digest/1 is the approved digest until a source snapshot exists" do
      scope = resources_fixture().scope

      assert Scope.source_snapshot(scope) == nil
      assert Scope.context_digest(scope) == Scope.approved_digest(scope)

      approved = approved_scope(resources_fixture())

      assert Scope.context_digest(approved) == Scope.approved_digest(approved)
    end

    test "with_source_snapshot/2 admits a bounded payload and computes its own digest" do
      context = Scope.context({:version, Ecto.UUID.generate()})
      payload = %{"trip_ids" => [Ecto.UUID.generate()], "delta_seconds" => 300}

      assert {:ok, admitted} =
               Scope.with_source_snapshot(context, %{kind: " dated_changes ", payload: payload})

      snapshot = Scope.source_snapshot(admitted)
      assert snapshot.kind == "dated_changes"
      assert snapshot.payload == payload
      assert snapshot.digest =~ ~r/\A[0-9a-f]{64}\z/

      # The same payload and kind digest identically; any value change does not.
      assert {:ok, again} =
               Scope.with_source_snapshot(context, %{kind: "dated_changes", payload: payload})

      assert Scope.source_snapshot(again).digest == snapshot.digest

      assert {:ok, other} =
               Scope.with_source_snapshot(context, %{
                 kind: "dated_changes",
                 payload: %{payload | "delta_seconds" => 600}
               })

      refute Scope.source_snapshot(other).digest == snapshot.digest
    end

    test "with_source_snapshot/2 refuses a caller digest and a non-JSON-safe payload" do
      context = Scope.context({:version, Ecto.UUID.generate()})

      # A caller may not assert a digest for a payload this module never measured.
      assert Scope.with_source_snapshot(context, %{
               kind: "dated_changes",
               payload: %{"a" => 1},
               digest: String.duplicate("0", 64)
             }) == {:error, :invalid_snapshot}

      date_payload = %{"at" => ~D[2026-11-02]}
      atom_payload = %{atom_key: "value"}
      tuple_payload = %{"value" => {1, 2}}
      pid_payload = %{"value" => self()}
      list_payload = ["not", "a", "map"]

      for payload <- [date_payload, atom_payload, tuple_payload, pid_payload, list_payload] do
        assert Scope.with_source_snapshot(context, %{kind: "dated_changes", payload: payload}) ==
                 {:error, :invalid_snapshot}
      end

      for kind <- ["", "   ", String.duplicate("k", 65), :dated_changes] do
        assert Scope.with_source_snapshot(context, %{kind: kind, payload: %{}}) ==
                 {:error, :invalid_snapshot}
      end
    end

    test "with_source_snapshot/2 refuses a whole context over the byte cap, equality allowed" do
      context = Scope.context({:version, Ecto.UUID.generate()})

      # The cap is on the whole tagged context, so the boundary is located
      # rather than estimated, and nearly the whole cap is usable.
      largest = largest_admitted(context)

      assert largest > Scope.max_context_bytes() - 500

      # Equality is admitted; one more byte is not.
      assert {:ok, _admitted} =
               Scope.with_source_snapshot(context, %{
                 kind: "k",
                 payload: %{"a" => String.duplicate("x", largest)}
               })

      assert Scope.with_source_snapshot(context, %{
               kind: "k",
               payload: %{"a" => String.duplicate("x", largest + 1)}
             }) == {:error, :too_large}
    end
  end

  describe "authorized_context/1" do
    test "refuses a snapshot whose payload no longer matches its digest" do
      context = resources_fixture()
      scope = source_snapshot_scope(context)

      assert Scope.authorized_context(scope) == :ok

      snapshot = Scope.source_snapshot(scope)
      tampered = Map.put(snapshot, :payload, Map.put(snapshot.payload, "delta_seconds", 86_400))

      assert Scope.authorized_context(tampered_scope(scope, tampered)) == {:error, :unavailable}
    end

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

  # The largest single payload value this context admits, found by doubling until
  # the cap refuses and then bisecting, so the boundary is measured.
  defp largest_admitted(context) do
    probe = fn size ->
      match?(
        {:ok, _context},
        Scope.with_source_snapshot(context, %{
          kind: "k",
          payload: %{"a" => String.duplicate("x", size)}
        })
      )
    end

    too_large = Enum.find(Stream.iterate(1024, &(&1 * 2)), &(not probe.(&1)))

    bisect_payload(probe, 1024, too_large - 1)
  end

  defp bisect_payload(_probe, low, high) when low >= high, do: high

  defp bisect_payload(probe, low, high) do
    middle = div(low + high, 2)

    if probe.(middle) do
      bisect_payload(probe, middle + 1, high)
    else
      bisect_payload(probe, low, middle - 1)
    end
  end

  # The whole-version identity a Calendars page binds.
  defp version_scope(context) do
    %{context.scope | resource_context: Scope.context({:version, context.version.id})}
  end

  # The single-route identity a Route schedules page binds.
  defp route_scope(context) do
    %{context.scope | resource_context: Scope.context({:route, context.route.id})}
  end

  # The same route identity carrying an accepted dated-change source, so the
  # remeasurement in `authorized_context/1` has a snapshot to remeasure.
  defp source_snapshot_scope(context) do
    scope = route_scope(context)

    {:ok, resource_context} =
      Scope.with_source_snapshot(
        scope.resource_context,
        %{
          kind: "dated_changes",
          payload: %{"trip_ids" => [Ecto.UUID.generate()], "delta_seconds" => 300}
        }
      )

    %{scope | resource_context: resource_context}
  end

  # The same scope with a replaced snapshot, used to present a payload that no
  # longer matches the digest the envelope computed.
  defp tampered_scope(scope, snapshot) do
    %{
      scope
      | resource_context: Map.put(scope.resource_context, :source_snapshot, snapshot)
    }
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
