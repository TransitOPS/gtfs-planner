defmodule GtfsPlanner.Gtfs.StopEditingMetadataApplyTest do
  @moduledoc """
  Merge evidence (EV-11) for `StopEditing.apply_metadata_batch/3`.

  The write is all-or-none and fenced on the review's fingerprint, so every refused
  case looks at the rows afterwards: no stop changed and no audit entry exists. The
  last case is a genuine interleaving on independent committed connections: an
  editor commits a rename of one reviewed stop while the apply waits for its row
  lock, and the apply then refuses the whole batch, leaving the other stop alone.
  The test environment's transaction runner is READ COMMITTED, so this shows the lock
  wait and the post-lock recheck; the SERIALIZABLE retry is the existing runner
  contract and is not exercised here.
  """

  use GtfsPlanner.DataCase, async: false

  import GtfsPlanner.ConcurrencyHelpers
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Gtfs.AuditContext
  alias GtfsPlanner.Gtfs.ChangeLog
  alias GtfsPlanner.Gtfs.Stop
  alias GtfsPlanner.Gtfs.StopEditing

  @rendezvous_timeout 10_000
  @collect_timeout 15_000

  setup do
    {fixture, _membership} = seed(true)
    fixture
  end

  describe "a reviewed batch" do
    test "saves only the four text fields and audits each changed stop once", context do
      %{"S410" => eb, "S411" => wb, "S500" => oak} = context.stops
      before = Map.new([eb, wb, oak], &{&1.stop_id, Repo.reload!(&1)})

      rows = [
        row(eb, %{"stop_name" => "Main & St Paul EB", "stop_url" => "https://example.org/eb"}),
        row(wb, %{"stop_desc" => "Westbound platform"}),
        row(oak, %{"stop_code" => " 500 "})
      ]

      review = review!(rows, context)
      assert {review.changed, review.unchanged, review.valid?} == {2, 1, true}

      assert {:ok, %{stops: stops, unchanged: 1}} =
               StopEditing.apply_metadata_batch(rows, review.fingerprint, context.audit)

      assert Enum.sort(Enum.map(stops, & &1.stop_id)) == ["S410", "S411"]

      eb_after = Repo.reload!(eb)

      assert {eb_after.stop_name, eb_after.stop_url} ==
               {"Main & St Paul EB", "https://example.org/eb"}

      assert Repo.reload!(wb).stop_desc == "Westbound platform"

      # Everything else on every stop is exactly as seeded, including the unchanged one.
      for stop <- [eb, wb, oak] do
        after_stop = Repo.reload!(stop)
        before_stop = before[stop.stop_id]

        # `lock_version` is the row's optimistic-lock counter and moves with any save.
        untouched = ~w(stop_name stop_code stop_desc stop_url lock_version)a

        assert Map.drop(Map.from_struct(after_stop), [:updated_at | untouched]) ==
                 Map.drop(Map.from_struct(before_stop), [:updated_at | untouched])
      end

      # The unchanged row was not written at all.
      assert Repo.reload!(oak) == before["S500"]

      logs = stop_logs(context)
      assert length(logs) == 2
      assert Enum.sort(Enum.map(logs, & &1.entity_id)) == Enum.sort([eb.id, wb.id])
      assert Enum.all?(logs, &(&1.action == "updated" and &1.actor_id == context.audit.actor_id))

      by_stop = Map.new(logs, &{&1.entity_id, &1.changed_fields})
      assert Map.keys(by_stop[eb.id]) |> Enum.sort() == ["stop_name", "stop_url"]
      assert Map.keys(by_stop[wb.id]) == ["stop_desc"]
    end

    test "an invalid row or a deleted stop writes nothing", context do
      %{"S410" => eb, "S411" => wb} = context.stops
      rows = [row(eb, %{"stop_name" => "Renamed"}), row(wb, %{"stop_url" => "ftp://nope"})]
      before = {stamps(), stop_logs(context)}

      review = review!(rows, context)
      assert review.valid? == false

      assert StopEditing.apply_metadata_batch(rows, review.fingerprint, context.audit) ==
               {:error, :invalid_rows}

      assert {stamps(), stop_logs(context)} == before

      good = [row(eb, %{"stop_name" => "Renamed"}), row(wb, %{"stop_name" => "Also renamed"})]
      good_review = review!(good, context)
      Repo.delete!(wb)
      before = {stamps(), stop_logs(context)}

      assert StopEditing.apply_metadata_batch(good, good_review.fingerprint, context.audit) ==
               {:error, :not_found}

      assert {stamps(), stop_logs(context)} == before
    end

    test "a change to a reviewed stop after the review is stale, even within the second",
         context do
      %{"S410" => eb, "S411" => wb} = context.stops
      rows = [row(eb, %{"stop_name" => "Renamed"}), row(wb, %{"stop_name" => "Also renamed"})]
      review = review!(rows, context)

      # `update_all` leaves `updated_at` as it was; the stored content is in the fingerprint.
      Repo.update_all(from(s in Stop, where: s.id == ^wb.id),
        set: [stop_desc: "Edited elsewhere"]
      )

      before = {stamps(), stop_logs(context)}

      assert StopEditing.apply_metadata_batch(rows, review.fingerprint, context.audit) ==
               {:error, :stale_review}

      assert {stamps(), stop_logs(context)} == before
    end

    test "saves a rename together with a text change to a nameless generic node", context do
      %{"S500" => oak} = context.stops

      node =
        stop_fixture(context.organization.id, context.version.id, %{
          stop_id: "N900",
          stop_name: nil,
          stop_lat: nil,
          stop_lon: nil,
          location_type: 3
        })

      rows = [row(oak, %{"stop_name" => "Oak Avenue"}), row(node, %{"stop_desc" => "Stair"})]
      review = review!(rows, context)

      assert {:ok, %{stops: stops, unchanged: 0}} =
               StopEditing.apply_metadata_batch(rows, review.fingerprint, context.audit)

      assert length(stops) == 2

      assert {Repo.reload!(oak).stop_name, Repo.reload!(node).stop_desc} ==
               {"Oak Avenue", "Stair"}
    end

    test "applying the same review twice saves once and then refuses", context do
      %{"S410" => eb} = context.stops
      rows = [row(eb, %{"stop_name" => "Renamed"})]
      review = review!(rows, context)

      assert {:ok, %{stops: [_one]}} =
               StopEditing.apply_metadata_batch(rows, review.fingerprint, context.audit)

      logs = stop_logs(context)
      assert length(logs) == 1

      assert StopEditing.apply_metadata_batch(rows, review.fingerprint, context.audit) ==
               {:error, :stale_review}

      assert stop_logs(context) == logs
    end

    test "a wrong fingerprint, a non-editor, a deactivated member and a foreign stop write nothing",
         context do
      %{"S410" => eb} = context.stops
      rows = [row(eb, %{"stop_name" => "Renamed"})]
      review = review!(rows, context)
      before = {stamps(), stop_logs(context)}

      assert StopEditing.apply_metadata_batch(rows, "0000", context.audit) ==
               {:error, :stale_review}

      assert StopEditing.apply_metadata_batch(rows, nil, context.audit) == {:error, :stale_review}

      stranger = user_fixture()
      stranger_audit = %{context.audit | actor_id: stranger.id, actor_email: stranger.email}

      assert StopEditing.apply_metadata_batch(rows, review.fingerprint, stranger_audit) ==
               {:error, :forbidden}

      other_version = gtfs_version_fixture(context.organization.id)
      other_audit = %{context.audit | gtfs_version_id: other_version.id}

      assert StopEditing.apply_metadata_batch(rows, review.fingerprint, other_audit) ==
               {:error, :not_found}

      deactivate_membership_fixture(context.membership)

      assert StopEditing.apply_metadata_batch(rows, review.fingerprint, context.audit) ==
               {:error, :forbidden}

      assert {stamps(), stop_logs(context)} == before
    end

    test "input errors are answered before any transaction opens", context do
      %{"S410" => eb} = context.stops
      good = %{stop_uuid: eb.id, changes: %{"stop_name" => "X"}}
      too_many = for _ <- 1..101, do: %{good | stop_uuid: Ecto.UUID.generate()}

      assert StopEditing.apply_metadata_batch(too_many, "x", context.audit) == {:error, :too_many}
      assert StopEditing.apply_metadata_batch([], "x", context.audit) == {:error, :invalid_input}

      assert StopEditing.apply_metadata_batch(
               [%{good | changes: %{"stop_lat" => "1"}}],
               "x",
               context.audit
             ) ==
               {:error, :invalid_input}

      assert StopEditing.apply_metadata_batch([good, good], "x", context.audit) ==
               {:error, :invalid_input}
    end
  end

  describe "against a concurrent committed edit" do
    @describetag :interleaving

    test "waits for a stop another connection holds, then refuses the whole batch" do
      supervisor = start_supervised!({Task.Supervisor, name: __MODULE__.TaskSupervisor})
      {scope, _membership} = unboxed(fn -> seed(false) end)
      on_exit(fn -> unboxed(fn -> cleanup(scope) end) end)

      [first, second] =
        scope.stops |> Map.take(["S410", "S411"]) |> Map.values() |> Enum.sort_by(& &1.id)

      rows = [
        row(first, %{"stop_name" => "First renamed"}),
        row(second, %{"stop_name" => "Second renamed"})
      ]

      review = unboxed(fn -> review!(rows, scope) end)

      parent = self()

      holder =
        Task.Supervisor.async_nolink(supervisor, fn ->
          unboxed(fn ->
            Repo.transaction(fn ->
              Repo.query!("SELECT 1 FROM stops WHERE id = $1 FOR UPDATE", [
                Ecto.UUID.dump!(second.id)
              ])

              send(parent, {:locked, backend_pid()})

              receive do
                :release -> :ok
              after
                @rendezvous_timeout -> raise "holder was not released"
              end

              Repo.update_all(from(s in Stop, where: s.id == ^second.id),
                set: [stop_name: "Renamed by another editor"]
              )
            end)
          end)
        end)

      assert_receive {:locked, holder_backend}, @rendezvous_timeout

      applier =
        Task.Supervisor.async_nolink(supervisor, fn ->
          unboxed(fn ->
            send(parent, {:applying, backend_pid()})
            StopEditing.apply_metadata_batch(rows, review.fingerprint, scope.audit)
          end)
        end)

      assert_receive {:applying, apply_backend}, @rendezvous_timeout

      # The apply is genuinely blocked on the holder's row lock.
      assert await_blocker(
               apply_backend,
               holder_backend,
               System.monotonic_time(:millisecond) + 10_000
             ) == :ok

      send(holder.pid, :release)
      assert {:ok, _} = Task.await(holder, @collect_timeout)
      assert Task.await(applier, @collect_timeout) == {:error, :stale_review}

      unboxed(fn ->
        assert Repo.reload!(first).stop_name == first.stop_name
        assert Repo.reload!(second).stop_name == "Renamed by another editor"

        assert Repo.aggregate(
                 from(l in ChangeLog, where: l.organization_id == ^scope.organization.id),
                 :count
               ) == 0
      end)
    end
  end

  # -- helpers ----------------------------------------------------------------

  defp row(stop, changes), do: %{stop_uuid: stop.id, changes: changes}

  defp review!(rows, context) do
    {:ok, review} = StopEditing.review_metadata_batch(rows, context.audit)
    review
  end

  defp stamps do
    Repo.all(
      from(s in Stop,
        order_by: s.id,
        select: {s.id, s.updated_at, s.stop_name, s.stop_code, s.stop_desc, s.stop_url}
      )
    )
  end

  defp stop_logs(context) do
    Repo.all(
      from(l in ChangeLog,
        where: l.organization_id == ^context.organization.id and l.entity_type == "stop",
        order_by: l.id
      )
    )
  end

  defp seed(_committed?) do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    actor = user_fixture()

    {:ok, membership} =
      Accounts.create_user_org_membership(%{
        user_id: actor.id,
        organization_id: organization.id,
        roles: ["pathways_studio_editor"]
      })

    audit = %AuditContext{
      organization_id: organization.id,
      gtfs_version_id: version.id,
      actor_id: actor.id,
      actor_email: actor.email
    }

    # The insert fixture's changeset does not cast `stop_code` or `stop_url`, so they
    # are written after it the way an import's bulk insert stores them.
    stop = fn id, name ->
      stop =
        stop_fixture(organization.id, version.id, %{
          stop_id: id,
          stop_name: name,
          stop_desc: "Stored description of #{id}",
          wheelchair_boarding: 1,
          stop_lat: Decimal.from_float(44.62),
          stop_lon: Decimal.from_float(-124.05)
        })

      Repo.update_all(from(s in Stop, where: s.id == ^stop.id),
        set: [stop_code: String.trim_leading(id, "S"), stop_url: "https://example.org/#{id}"]
      )

      Repo.reload!(stop)
    end

    stops = %{
      "S410" => stop.("S410", "Main St @ St Paul EB"),
      "S411" => stop.("S411", "Main St @ St Paul WB"),
      "S500" => stop.("S500", "Oak Ave")
    }

    {%{
       organization: organization,
       version: version,
       audit: audit,
       stops: stops,
       actor: actor,
       membership: membership
     }, membership}
  end

  defp cleanup(scope) do
    delete_committed_scope!([scope.organization.id])
    Repo.delete_all(from(u in GtfsPlanner.Accounts.User, where: u.id == ^scope.actor.id))
  end
end
