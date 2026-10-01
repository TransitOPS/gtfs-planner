defmodule GtfsPlanner.Gtfs.Blocking.SettingsTest do
  @moduledoc """
  The eight Block rules settings are read with their defaults, validated on every
  range, and written under the blocking lock, so an upsert that keeps a stale
  column, an unchecked range and a writer without the lock stay rejected.

  Rows are created inside the SQL Sandbox transaction and rolled back. The one
  exception is the lock case, which needs an organization and version that another
  connection can see: it commits its own disposable rows on an own connection and
  deletes exactly those rows in `on_exit`, like `concurrency_test.exs`.

  The module is `async: false` because the lock case observes another backend's
  `pg_stat_activity` wait; the settings cases themselves are sandboxed like any
  other `DataCase`.

  Run with:
  `mix test test/gtfs_planner/gtfs/blocking/settings_test.exs`.
  """
  use GtfsPlanner.DataCase, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias GtfsPlanner.Accounts.{User, UserOrgMembership}
  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.Blocking
  alias GtfsPlanner.Gtfs.BlockingSetting
  alias GtfsPlanner.Organizations.Organization
  alias GtfsPlanner.Versions
  alias GtfsPlanner.Versions.GtfsVersion

  import GtfsPlanner.OperationsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  @defaults %{
    min_layover_minutes: 5,
    max_block_minutes: nil,
    pull_out_buffer_minutes: 0,
    interlining: :any,
    default_garage_id: nil,
    deadhead_speed_kmh: 30,
    deadhead_circuity: 1.3,
    max_piece_minutes: nil
  }

  # Every field at a value that must be accepted, so one rejection case can override
  # a single field and the remaining error fields are not incidental.
  @valid %{
    min_layover_minutes: 8,
    max_block_minutes: 600,
    pull_out_buffer_minutes: 5,
    interlining: "same_stop",
    deadhead_speed_kmh: 40,
    deadhead_circuity: 1.4,
    max_piece_minutes: 330
  }

  @moduletag timeout: 120_000

  # The lock case holds one lock open and observes another backend's wait, so it is
  # bounded: a 120 s deadline per test, and a 10 s self-release for a
  # hold the test never gets to release.
  @hold_timeout 10_000
  @receive_timeout 5_000
  @lock_wait_attempts 500
  @task_timeout 15_000

  describe "get_settings/2" do
    test "an unset version reads every default and stores no row" do
      organization = organization_fixture()
      version = gtfs_version_fixture(organization.id)

      assert Blocking.get_settings(organization.id, version.id) == @defaults
      assert Repo.aggregate(BlockingSetting, :count) == 0
    end
  end

  describe "update_settings/2" do
    test "saving every field stores them and a second save replaces every column on the same row" do
      organization = organization_fixture()
      version = gtfs_version_fixture(organization.id)
      garage = garage_fixture(organization.id)
      other_garage = garage_fixture(organization.id)

      assert {:ok, first} =
               Blocking.update_settings(
                 GtfsPlanner.AccountsFixtures.editor_audit_fixture(organization.id, version.id),
                 Map.put(@valid, :default_garage_id, garage.id)
               )

      assert first.min_layover_minutes == 8
      assert first.max_block_minutes == 600
      assert first.pull_out_buffer_minutes == 5
      assert first.interlining == :same_stop
      assert first.default_garage_id == garage.id
      assert first.deadhead_speed_kmh == 40
      assert Decimal.equal?(first.deadhead_circuity, Decimal.new("1.4"))
      assert first.max_piece_minutes == 330

      assert Blocking.get_settings(organization.id, version.id) == %{
               min_layover_minutes: 8,
               max_block_minutes: 600,
               pull_out_buffer_minutes: 5,
               interlining: :same_stop,
               default_garage_id: garage.id,
               deadhead_speed_kmh: 40,
               deadhead_circuity: 1.4,
               max_piece_minutes: 330
             }

      # Every column is replaced, not merged: each field moves to a different value,
      # and the previously stored garage is gone rather than still referenced.
      replacement = %{
        min_layover_minutes: 12,
        max_block_minutes: 1440,
        pull_out_buffer_minutes: 60,
        interlining: "none",
        default_garage_id: other_garage.id,
        deadhead_speed_kmh: 120,
        deadhead_circuity: 2.5,
        max_piece_minutes: 720
      }

      assert {:ok, second} =
               Blocking.update_settings(
                 GtfsPlanner.AccountsFixtures.editor_audit_fixture(organization.id, version.id),
                 replacement
               )

      assert second.id == first.id
      assert Repo.aggregate(BlockingSetting, :count) == 1

      assert Blocking.get_settings(organization.id, version.id) == %{
               min_layover_minutes: 12,
               max_block_minutes: 1440,
               pull_out_buffer_minutes: 60,
               interlining: :none,
               default_garage_id: other_garage.id,
               deadhead_speed_kmh: 120,
               deadhead_circuity: 2.5,
               max_piece_minutes: 720
             }
    end

    test "a blank optional limit is stored as nil and a set one is replaced" do
      organization = organization_fixture()
      version = gtfs_version_fixture(organization.id)

      assert {:ok, _} =
               Blocking.update_settings(
                 GtfsPlanner.AccountsFixtures.editor_audit_fixture(organization.id, version.id),
                 @valid
               )

      assert Blocking.get_settings(organization.id, version.id).max_block_minutes == 600
      assert Blocking.get_settings(organization.id, version.id).max_piece_minutes == 330

      assert {:ok, _} =
               Blocking.update_settings(
                 GtfsPlanner.AccountsFixtures.editor_audit_fixture(organization.id, version.id),
                 %{
                   @valid
                   | max_block_minutes: "",
                     max_piece_minutes: ""
                 }
               )

      settings = Blocking.get_settings(organization.id, version.id)
      assert settings.max_block_minutes == nil
      assert settings.max_piece_minutes == nil
    end

    test "each out-of-range value returns its field error and stores nothing" do
      organization = organization_fixture()
      version = gtfs_version_fixture(organization.id)

      assert_rejected(organization.id, version.id, :min_layover_minutes, 121)
      assert_rejected(organization.id, version.id, :max_block_minutes, 59)
      assert_rejected(organization.id, version.id, :max_block_minutes, 1441)
      assert_rejected(organization.id, version.id, :pull_out_buffer_minutes, 61)
      assert_rejected(organization.id, version.id, :interlining, "sometimes")
      assert_rejected(organization.id, version.id, :deadhead_speed_kmh, 4)
      assert_rejected(organization.id, version.id, :deadhead_speed_kmh, 121)
      assert_rejected(organization.id, version.id, :deadhead_circuity, 0.9)
      assert_rejected(organization.id, version.id, :deadhead_circuity, 3.1)
      assert_rejected(organization.id, version.id, :max_piece_minutes, 59)
      assert_rejected(organization.id, version.id, :max_piece_minutes, 721)

      assert Repo.aggregate(BlockingSetting, :count) == 0
    end

    test "a blank required value is rejected" do
      organization = organization_fixture()
      version = gtfs_version_fixture(organization.id)

      assert_rejected(organization.id, version.id, :min_layover_minutes, "")
      assert_rejected(organization.id, version.id, :min_layover_minutes, "abc")
      assert_rejected(organization.id, version.id, :min_layover_minutes, -1)

      assert Repo.aggregate(BlockingSetting, :count) == 0
    end

    test "a default garage of another organization is a field error and stores nothing" do
      organization = organization_fixture()
      version = gtfs_version_fixture(organization.id)
      other_organization = organization_fixture()
      foreign_garage = garage_fixture(other_organization.id)

      assert_rejected(
        organization.id,
        version.id,
        :default_garage_id,
        foreign_garage.id
      )

      assert Repo.aggregate(BlockingSetting, :count) == 0

      # The same field with a garage of this organization is stored.
      garage = garage_fixture(organization.id)

      assert {:ok, %BlockingSetting{default_garage_id: stored}} =
               Blocking.update_settings(
                 GtfsPlanner.AccountsFixtures.editor_audit_fixture(organization.id, version.id),
                 Map.put(@valid, :default_garage_id, garage.id)
               )

      assert stored == garage.id
      assert Blocking.get_settings(organization.id, version.id).default_garage_id == garage.id
    end

    test "a rejected save leaves the stored row exactly as the previous save left it" do
      organization = organization_fixture()
      version = gtfs_version_fixture(organization.id)
      garage = garage_fixture(organization.id)

      assert {:ok, _} =
               Blocking.update_settings(
                 GtfsPlanner.AccountsFixtures.editor_audit_fixture(organization.id, version.id),
                 Map.put(@valid, :default_garage_id, garage.id)
               )

      stored = Blocking.get_settings(organization.id, version.id)

      assert {:error, _} =
               Blocking.update_settings(
                 GtfsPlanner.AccountsFixtures.editor_audit_fixture(organization.id, version.id),
                 %{
                   @valid
                   | min_layover_minutes: 121
                 }
               )

      assert Blocking.get_settings(organization.id, version.id) == stored
      assert Repo.aggregate(BlockingSetting, :count) == 1
    end

    test "the database refuses an out-of-range value written outside the changeset" do
      organization = organization_fixture()
      version = gtfs_version_fixture(organization.id)

      # The struct insert declares no check_constraint, so Ecto surfaces the
      # PostgreSQL check violation as Ecto.ConstraintError naming the constraint.
      assert_raise Ecto.ConstraintError, ~r/min_layover_range/, fn ->
        Repo.transaction(fn ->
          Repo.insert!(%BlockingSetting{
            organization_id: organization.id,
            gtfs_version_id: version.id,
            min_layover_minutes: 121
          })
        end)
      end

      # Each widened column keeps its own named constraint in the database, not just
      # in the changeset.
      out_of_range_columns = [
        max_block_minutes: {59, "max_block_minutes_range"},
        pull_out_buffer_minutes: {61, "pull_out_buffer_range"},
        deadhead_speed_kmh: {4, "deadhead_speed_range"},
        deadhead_circuity: {Decimal.new("3.1"), "deadhead_circuity_range"},
        max_piece_minutes: {59, "max_piece_minutes_range"}
      ]

      for {column, {value, constraint}} <- out_of_range_columns do
        setting =
          struct(%BlockingSetting{
            organization_id: organization.id,
            gtfs_version_id: version.id,
            min_layover_minutes: 5
          })
          |> Map.replace!(column, value)

        assert_raise Ecto.ConstraintError, ~r/#{constraint}/, fn ->
          Repo.transaction(fn -> Repo.insert!(setting) end)
        end
      end

      # `interlining` is an Ecto enum, so the database never sees the bad value:
      # the struct cannot be loaded at all. That is a different refusal from the
      # CHECK constraints above, and it is the one the schema can make.
      interlining =
        struct(%BlockingSetting{
          organization_id: organization.id,
          gtfs_version_id: version.id,
          min_layover_minutes: 5
        })
        |> Map.replace!(:interlining, "sometimes")

      assert_raise Ecto.ChangeError, ~r/interlining/, fn ->
        Repo.insert!(interlining)
      end
    end

    test "a staging version and another organization's version are not found" do
      organization = organization_fixture()
      {:ok, staging} = Versions.create_staging_gtfs_version(organization.id, %{name: "Staging"})
      other_organization = organization_fixture()
      foreign_version = gtfs_version_fixture(other_organization.id)

      assert Blocking.update_settings(
               GtfsPlanner.AccountsFixtures.editor_audit_fixture(organization.id, staging.id),
               @valid
             ) ==
               {:error, :not_found}

      assert Blocking.update_settings(
               GtfsPlanner.AccountsFixtures.editor_audit_fixture(
                 organization.id,
                 foreign_version.id
               ),
               @valid
             ) ==
               {:error, :not_found}

      assert Repo.aggregate(BlockingSetting, :count) == 0
    end

    test "two versions of one organization keep separate values" do
      organization = organization_fixture()
      version = gtfs_version_fixture(organization.id)
      other_version = gtfs_version_fixture(organization.id)

      assert {:ok, %BlockingSetting{}} =
               Blocking.update_settings(
                 GtfsPlanner.AccountsFixtures.editor_audit_fixture(organization.id, version.id),
                 %{
                   @valid
                   | min_layover_minutes: 12
                 }
               )

      assert {:ok, %BlockingSetting{}} =
               Blocking.update_settings(
                 GtfsPlanner.AccountsFixtures.editor_audit_fixture(
                   organization.id,
                   other_version.id
                 ),
                 %{
                   @valid
                   | min_layover_minutes: 30
                 }
               )

      assert Blocking.get_settings(organization.id, version.id).min_layover_minutes == 12
      assert Blocking.get_settings(organization.id, other_version.id).min_layover_minutes == 30

      assert Repo.aggregate(BlockingSetting, :count) == 2
    end

    test "submitted organization and version IDs are ignored" do
      organization = organization_fixture()
      version = gtfs_version_fixture(organization.id)
      other_organization = organization_fixture()
      foreign_version = gtfs_version_fixture(other_organization.id)

      attrs =
        Map.merge(%{@valid | min_layover_minutes: 12}, %{
          organization_id: other_organization.id,
          gtfs_version_id: foreign_version.id
        })

      assert {:ok, stored} =
               Blocking.update_settings(
                 GtfsPlanner.AccountsFixtures.editor_audit_fixture(organization.id, version.id),
                 attrs
               )

      assert stored.organization_id == organization.id
      assert stored.gtfs_version_id == version.id
      assert Blocking.get_settings(organization.id, version.id).min_layover_minutes == 12

      assert Blocking.get_settings(other_organization.id, foreign_version.id) == @defaults
    end
  end

  describe "update_settings/2 under a held blocking lock" do
    test "the writer waits for lock_blocking!1 and succeeds after the release" do
      scope =
        unboxed(fn ->
          organization = organization_fixture()
          version = gtfs_version_fixture(organization.id)
          %{organization_id: organization.id, version_id: version.id}
        end)

      on_exit(fn -> cleanup_committed_scope(scope) end)

      parent = self()

      holder = Task.async(fn -> hold_blocking_lock(scope, parent) end)
      assert_receive :blocking_lock_held, @receive_timeout

      writer =
        Task.async(fn ->
          unboxed(fn ->
            {:ok, %{rows: [[backend_pid]]}} = Repo.query("select pg_backend_pid()")
            send(parent, {:writer_pid, backend_pid})

            Blocking.update_settings(
              GtfsPlanner.AccountsFixtures.editor_audit_fixture(
                scope.organization_id,
                scope.version_id
              ),
              @valid
            )
          end)
        end)

      assert_receive {:writer_pid, writer_pid}, @receive_timeout

      # The writer is inside its own transaction and waiting for the advisory lock the
      # holder's connection owns. `lock_blocking!/1` issues exactly this lock.
      assert wait_until_locked(writer_pid)

      send(holder.pid, :release)
      Task.await(holder, @task_timeout)

      assert {:ok, %BlockingSetting{min_layover_minutes: 8}} = Task.await(writer, @task_timeout)

      settings = unboxed(fn -> Blocking.get_settings(scope.organization_id, scope.version_id) end)
      assert settings.min_layover_minutes == 8
    end
  end

  describe "change_settings/2" do
    test "renders every current value and reports an out-of-range change" do
      changeset = Blocking.change_settings(@defaults, %{})

      for field <- [:min_layover_minutes, :pull_out_buffer_minutes, :deadhead_speed_kmh] do
        assert Ecto.Changeset.get_field(changeset, field) == Map.fetch!(@defaults, field)
      end

      assert Ecto.Changeset.get_field(changeset, :interlining) == :any
      assert Ecto.Changeset.get_field(changeset, :deadhead_circuity) == 1.3
      assert Ecto.Changeset.get_field(changeset, :max_block_minutes) == nil

      changeset =
        Blocking.change_settings(@defaults, %{min_layover_minutes: 121})

      refute changeset.valid?

      assert %{min_layover_minutes: ["must be a whole number between 0 and 120"]} =
               errors_on(changeset)
    end

    test "a partial map is filled from the defaults" do
      # The Blocks page's layover drawer still passes only the one value it renders.
      changeset = Blocking.change_settings(%{min_layover_minutes: 12}, %{})

      assert Ecto.Changeset.get_field(changeset, :min_layover_minutes) == 12
      assert Ecto.Changeset.get_field(changeset, :deadhead_speed_kmh) == 30
      assert Ecto.Changeset.get_field(changeset, :interlining) == :any
    end
  end

  describe "Gtfs facade" do
    test "the facade reaches the same setting read and write" do
      organization = organization_fixture()
      version = gtfs_version_fixture(organization.id)

      assert Gtfs.get_blocking_settings(organization.id, version.id) == @defaults

      assert {:ok, %BlockingSetting{min_layover_minutes: 12}} =
               Gtfs.update_blocking_settings(
                 GtfsPlanner.AccountsFixtures.editor_audit_fixture(organization.id, version.id),
                 %{
                   @valid
                   | min_layover_minutes: 12
                 }
               )

      assert Gtfs.get_blocking_settings(organization.id, version.id).min_layover_minutes == 12
      assert Gtfs.get_blocking_settings(organization.id, version.id).max_block_minutes == 600
    end
  end

  defp assert_rejected(organization_id, gtfs_version_id, field, value) do
    assert {:error, changeset} =
             Blocking.update_settings(
               GtfsPlanner.AccountsFixtures.editor_audit_fixture(
                 organization_id,
                 gtfs_version_id
               ),
               Map.put(@valid, field, value)
             )

    assert %{^field => [_message]} = errors_on(changeset)
  end

  defp unboxed(fun), do: Sandbox.unboxed_run(Repo, fun)

  # Holds the version's blocking lock on an own connection, with the statement
  # `Blocking.lock_blocking!/1` issues, until the test releases it.
  defp hold_blocking_lock(scope, parent) do
    unboxed(fn ->
      Repo.transaction(fn ->
        Repo.query!("SELECT pg_advisory_xact_lock(hashtext($1))", [
          "blocking:" <> scope.version_id
        ])

        send(parent, :blocking_lock_held)

        receive do
          :release -> :ok
        after
          @hold_timeout -> Repo.rollback(:timeout)
        end
      end)
    end)
  end

  # Deletes exactly the rows the lock case committed, keyed to their own organization,
  # on an own connection so the deletion is not part of the sandboxed test transaction.
  # Both `blocking_settings` foreign keys cascade, so the settings rows go with the
  # version.
  defp cleanup_committed_scope(scope) do
    unboxed(fn ->
      actor_ids =
        Repo.all(
          from(m in UserOrgMembership,
            where: m.organization_id == ^scope.organization_id,
            select: m.user_id
          )
        )

      Repo.delete_all(
        from(m in UserOrgMembership, where: m.organization_id == ^scope.organization_id)
      )

      Repo.delete_all(from(v in GtfsVersion, where: v.organization_id == ^scope.organization_id))
      Repo.delete_all(from(o in Organization, where: o.id == ^scope.organization_id))
      Repo.delete_all(from(u in User, where: u.id in ^actor_ids))
    end)
  end

  defp wait_until_locked(pid, attempts \\ @lock_wait_attempts) do
    {:ok, %{rows: [[waiting]]}} =
      Repo.query(
        "select count(*) from pg_stat_activity where pid = $1 and wait_event_type = 'Lock'",
        [pid]
      )

    cond do
      waiting > 0 ->
        true

      attempts <= 0 ->
        flunk("the backend #{inspect(pid)} never waited on a lock")

      true ->
        Process.sleep(10)
        wait_until_locked(pid, attempts - 1)
    end
  end
end
