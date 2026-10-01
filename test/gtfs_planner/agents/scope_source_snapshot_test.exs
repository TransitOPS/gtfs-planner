defmodule GtfsPlanner.Agents.ScopeSourceSnapshotTest do
  @moduledoc """
  The shared source-snapshot foundation AI-07 step 2 depends on.

  Scope owns the envelope only: its shape, the server-computed digest, the
  whole-context size admission and the session-key binding. The resource IDs
  inside a payload belong to a pack's `authorize_context/1`, which is exercised
  where a pack exists.
  """

  use GtfsPlanner.DataCase, async: true

  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Agents.Scope

  @snapshot %{kind: "station_results", payload: %{"station_id" => "s", "station_stop_id" => "ST"}}

  describe "with_source_snapshot/2" do
    test "admits a bounded payload and computes the digest itself" do
      assert {:ok, context} =
               Scope.with_source_snapshot(Scope.context({:version, id()}), @snapshot)

      snapshot = Scope.source_snapshot(scope_with(context))

      assert snapshot.kind == "station_results"
      assert snapshot.payload == @snapshot.payload
      assert byte_size(snapshot.digest) == 64
      assert snapshot.digest =~ ~r/\A[0-9a-f]{64}\z/
    end

    test "refuses a blank or overlong kind, a non-JSON payload and a caller-supplied digest" do
      context = Scope.context({:version, id()})

      assert {:error, :invalid_snapshot} =
               Scope.with_source_snapshot(context, %{kind: "   ", payload: %{}})

      assert {:error, :invalid_snapshot} =
               Scope.with_source_snapshot(context, %{
                 kind: String.duplicate("k", 65),
                 payload: %{}
               })

      assert {:error, :invalid_snapshot} =
               Scope.with_source_snapshot(context, %{
                 kind: "station_results",
                 payload: %{"station_id" => ~D[2026-10-02]}
               })

      assert {:error, :invalid_snapshot} =
               Scope.with_source_snapshot(context, %{
                 kind: "station_results",
                 payload: %{"station_id" => :an_atom}
               })

      assert {:error, :invalid_snapshot} =
               Scope.with_source_snapshot(context, %{
                 kind: "station_results",
                 payload: %{"digest" => String.duplicate("0", 64)}
               })

      # A snapshot that was never attached leaves the context unchanged.
      assert Scope.context({:version, id()}).source_snapshot == nil
    end

    test "measures the whole serialized resource context against 65,536 bytes" do
      context = Scope.context({:version, id()})

      assert {:ok, admitted} =
               Scope.with_source_snapshot(context, %{
                 kind: "station_results",
                 payload: %{"station_id" => String.duplicate("a", 60_000)}
               })

      assert Scope.source_snapshot(scope_with(admitted)).payload["station_id"] ==
               String.duplicate("a", 60_000)

      assert {:error, :too_large} =
               Scope.with_source_snapshot(context, %{
                 kind: "station_results",
                 payload: %{"station_id" => String.duplicate("a", 66_000)}
               })
    end
  end

  describe "source_snapshot/1" do
    test "reads back an admitted envelope and refuses a forged digest" do
      assert {:ok, context} =
               Scope.with_source_snapshot(Scope.context({:version, id()}), @snapshot)

      assert %{kind: "station_results"} = Scope.source_snapshot(scope_with(context))

      forged = %{
        context
        | source_snapshot: %{context.source_snapshot | digest: String.duplicate("0", 64)}
      }

      assert Scope.source_snapshot(scope_with(forged)) == nil
    end

    test "treats a legacy context without the key as no snapshot" do
      scope = %Scope{
        organization_id: id(),
        gtfs_version_id: id(),
        user_id: id(),
        pack_id: "calendars"
      }

      assert Scope.source_snapshot(scope) == nil
    end
  end

  describe "context_digest/1" do
    test "binds the source snapshot and the approval, and is stable for one context" do
      assert {:ok, one} = Scope.with_source_snapshot(Scope.context({:version, id()}), @snapshot)

      assert {:ok, other} =
               Scope.with_source_snapshot(Scope.context({:version, id()}), %{
                 kind: "station_results",
                 payload: %{"station_id" => "different"}
               })

      assert {:ok, no_snapshot} =
               Scope.with_source_snapshot(Scope.context({:version, id()}), %{
                 kind: "station_results",
                 payload: %{}
               })

      scope_one = scope_with(one)
      scope_other = scope_with(other)
      bare = scope_with(no_snapshot)
      bare_no_kind = scope_with(Map.put(no_snapshot, :source_snapshot, nil))

      assert Scope.context_digest(scope_one) == Scope.context_digest(scope_one)
      assert Scope.context_digest(scope_one) != Scope.context_digest(scope_other)
      assert Scope.context_digest(bare) != Scope.context_digest(scope_one)
      assert Scope.context_digest(bare) != Scope.context_digest(bare_no_kind)

      approved = %{
        bare
        | resource_context: %{
            bare.resource_context
            | approved_extension: %{
                service_id: "SCHOOL_WD",
                end_date: ~D[2026-10-12],
                approval_text: "Extend the weekday calendar."
              }
          }
      }

      assert Scope.context_digest(approved) != Scope.context_digest(bare)
      assert Scope.approved_digest(approved) != "none"
    end
  end

  describe "authorized_context/1" do
    setup do
      organization = organization_fixture()
      user = user_fixture()
      organization_membership_fixture(user, organization)
      version = gtfs_version_fixture(organization.id)

      %{organization: organization, user: user, version: version}
    end

    test "admits an attached snapshot for an active editor", ctx do
      {:ok, resource_context} =
        Scope.context({:version, ctx.version.id})
        |> Scope.with_source_snapshot(@snapshot)

      scope = authorized_scope(ctx, resource_context)

      assert Scope.authorized_context(scope) == :ok
    end

    test "refuses a forged or oversized envelope as an unavailable resource", ctx do
      {:ok, resource_context} =
        Scope.context({:version, ctx.version.id})
        |> Scope.with_source_snapshot(@snapshot)

      forged = %{
        resource_context
        | source_snapshot: %{resource_context.source_snapshot | digest: String.duplicate("0", 64)}
      }

      assert Scope.authorized_context(authorized_scope(ctx, forged)) == {:error, :unavailable}

      oversized = %{
        resource_context
        | source_snapshot: %{
            resource_context.source_snapshot
            | payload:
                Map.put(
                  resource_context.source_snapshot.payload,
                  "station_id",
                  String.duplicate("a", 70_000)
                )
          }
      }

      assert Scope.authorized_context(authorized_scope(ctx, oversized)) == {:error, :unavailable}
    end

    test "a context with no snapshot is unaffected", ctx do
      scope = authorized_scope(ctx, Scope.context({:version, ctx.version.id}))

      assert Scope.authorized_context(scope) == :ok
      assert Scope.source_snapshot(scope) == nil
    end
  end

  defp authorized_scope(ctx, resource_context) do
    %Scope{
      organization_id: ctx.organization.id,
      gtfs_version_id: ctx.version.id,
      user_id: ctx.user.id,
      user_email: ctx.user.email,
      pack_id: "calendars",
      version_name: ctx.version.name,
      resource_context: resource_context
    }
  end

  defp scope_with(resource_context) do
    %Scope{
      organization_id: id(),
      gtfs_version_id: id(),
      user_id: id(),
      pack_id: "calendars",
      resource_context: resource_context
    }
  end

  defp id, do: Ecto.UUID.generate()
end
