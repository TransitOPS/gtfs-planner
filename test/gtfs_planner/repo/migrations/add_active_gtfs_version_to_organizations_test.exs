defmodule GtfsPlanner.Repo.Migrations.AddActiveGtfsVersionToOrganizationsTest do
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL
  alias Ecto.Adapters.SQL.Sandbox
  alias Ecto.Migrator
  alias GtfsPlanner.Repo

  @migration_path Path.expand(
                    "../../../../priv/repo/migrations/20261003062816_add_active_gtfs_version_to_organizations.exs",
                    __DIR__
                  )
  Code.require_file(@migration_path)

  @migration_version @migration_path
                     |> Path.basename()
                     |> String.split("_", parts: 2)
                     |> hd()
                     |> String.to_integer()

  alias GtfsPlanner.Repo.Migrations.AddActiveGtfsVersionToOrganizations, as: Migration

  setup_all do
    Sandbox.mode(Repo, :auto)
    on_exit(fn -> Sandbox.mode(Repo, :manual) end)
    :ok
  end

  # Every organization below has hand-written versions; the expected selection is written
  # beside each one rather than derived from the migration's own ordering.
  setup do
    prefix = "test_active_selection_#{System.unique_integer([:positive])}"
    SQL.query!(Repo, ~s|CREATE SCHEMA "#{prefix}"|, [])
    on_exit(fn -> SQL.query!(Repo, ~s|DROP SCHEMA IF EXISTS "#{prefix}" CASCADE|, []) end)

    create_pre_migration_schema(prefix)
    organizations = seed_pre_migration_rows(prefix)
    Migrator.up(Repo, @migration_version, Migration, prefix: prefix, log: false)

    Map.put(organizations, :prefix, prefix)
  end

  describe "up/0" do
    test "selects the source a surviving export run proves for the served full manifest", c do
      # Newer usable versions exist; the served manifest came from the older one.
      assert selection_row(c.prefix, c.proven.org) == {c.proven.old, 1, 3}
    end

    test "prefers a frozen version id over an export run that no longer exists", c do
      assert selection_row(c.prefix, c.frozen.org) == {c.frozen.old, 1, 2}
    end

    test "initializes from the newest usable version when the served source is unusable, foreign or gone",
         c do
      assert selection_row(c.prefix, c.unusable.org) == {c.unusable.newest, 1, 4}
      assert selection_row(c.prefix, c.foreign.org) == {c.foreign.only, 1, 1}
      assert selection_row(c.prefix, c.collected.org) == {c.collected.newest, 1, 5}
    end

    test "orders the fallback by published_at, then inserted_at, with an unset published_at last",
         c do
      assert selection_row(c.prefix, c.ordering.org) == {c.ordering.chosen, 1, 0}
    end

    test "selects nothing for an organization without a usable version", c do
      assert selection_row(c.prefix, c.unusable_only.org) == {nil, 0, 0}
    end
  end

  describe "converted schema" do
    test "refuses a pointer to another organization's version and a negative counter", c do
      assert_raise Postgrex.Error, ~r/organizations_active_gtfs_version_owner_fkey/, fn ->
        SQL.query!(
          Repo,
          "UPDATE #{q(c.prefix)}.organizations SET active_gtfs_version_id = $1 WHERE id = $2",
          [dump(c.proven.old), dump(c.unusable_only.org)]
        )
      end

      for column <- ~w(active_gtfs_version_revision active_full_publication_sequence) do
        assert_raise Postgrex.Error, ~r/organizations_active_selection_nonnegative/, fn ->
          SQL.query!(Repo, "UPDATE #{q(c.prefix)}.organizations SET #{column} = -1", [])
        end
      end
    end

    test "refuses to delete the active version alone, yet deletes it with its organization", c do
      assert_raise Postgrex.Error, ~r/organizations_active_gtfs_version_owner_fkey/, fn ->
        SQL.query!(Repo, "DELETE FROM #{q(c.prefix)}.gtfs_versions WHERE id = $1", [
          dump(c.proven.old)
        ])
      end

      assert version_count(c.prefix, c.proven.org) == 3

      SQL.query!(Repo, "DELETE FROM #{q(c.prefix)}.organizations WHERE id = $1", [
        dump(c.proven.org)
      ])

      assert version_count(c.prefix, c.proven.org) == 0
    end

    test "deletes a version that is not active", c do
      SQL.query!(Repo, "DELETE FROM #{q(c.prefix)}.gtfs_versions WHERE id = $1", [
        dump(c.proven.newer)
      ])

      assert selection_row(c.prefix, c.proven.org) == {c.proven.old, 1, 3}
      assert version_count(c.prefix, c.proven.org) == 2
    end
  end

  describe "down/0" do
    test "drops the selection columns and their key", c do
      Migrator.down(Repo, @migration_version, Migration, prefix: c.prefix, log: false)

      assert %{rows: []} =
               SQL.query!(
                 Repo,
                 """
                 SELECT column_name FROM information_schema.columns
                 WHERE table_schema = $1 AND table_name = 'organizations'
                   AND column_name LIKE 'active_%'
                 """,
                 [c.prefix]
               )
    end
  end

  defp q(prefix), do: ~s|"#{prefix}"|
  defp dump(id), do: Ecto.UUID.dump!(id)

  # The pre-migration shape of the tables the migration reads or constrains. Columns the
  # migration never touches are left out.
  defp create_pre_migration_schema(prefix) do
    for statement <- [
          "CREATE TABLE #{q(prefix)}.organizations (id uuid PRIMARY KEY)",
          """
          CREATE TABLE #{q(prefix)}.gtfs_versions (
            id uuid PRIMARY KEY,
            organization_id uuid NOT NULL
              REFERENCES #{q(prefix)}.organizations (id) ON DELETE CASCADE,
            publication_status varchar NOT NULL,
            published_at timestamp,
            inserted_at timestamp NOT NULL
          )
          """,
          "CREATE UNIQUE INDEX ON #{q(prefix)}.gtfs_versions (id, organization_id)",
          """
          CREATE TABLE #{q(prefix)}.gtfs_export_runs (
            id uuid PRIMARY KEY,
            organization_id uuid NOT NULL,
            gtfs_version_id uuid NOT NULL
              REFERENCES #{q(prefix)}.gtfs_versions (id) ON DELETE CASCADE
          )
          """,
          """
          CREATE TABLE #{q(prefix)}.feed_publications (
            id uuid PRIMARY KEY,
            organization_id uuid NOT NULL,
            channel varchar NOT NULL,
            manifest_sequence bigint
          )
          """,
          """
          CREATE TABLE #{q(prefix)}.feed_publication_attempts (
            id uuid PRIMARY KEY,
            publication_id uuid NOT NULL,
            organization_id uuid NOT NULL,
            sequence bigint NOT NULL,
            private_snapshot jsonb
          )
          """
        ] do
      SQL.query!(Repo, statement, [])
    end
  end

  defp seed_pre_migration_rows(prefix) do
    # The served full manifest (sequence 3) came from the older of two usable versions.
    proven = organization_row(prefix)
    proven_old = version_row(prefix, proven, "published", "2026-01-01 00:00:00")
    proven_newer = version_row(prefix, proven, "published", "2026-03-01 00:00:00")
    _proven_staging = version_row(prefix, proven, "staging", nil)
    proven_run = export_run_row(prefix, proven, proven_old)
    full_publication_row(prefix, proven, 3, %{"source" => %{"run_id" => proven_run}})

    # The frozen version id names the older version; its export run is long gone.
    frozen = organization_row(prefix)
    frozen_old = version_row(prefix, frozen, "published", "2026-01-01 00:00:00")
    _frozen_new = version_row(prefix, frozen, "published", "2026-03-01 00:00:00")

    full_publication_row(prefix, frozen, 2, %{
      "source" => %{"gtfs_version_id" => frozen_old, "run_id" => Ecto.UUID.generate()}
    })

    # The served source is a staging version, so it proves nothing usable.
    unusable = organization_row(prefix)
    _unusable_old = version_row(prefix, unusable, "published", "2026-01-01 00:00:00")
    unusable_newest = version_row(prefix, unusable, "published", "2026-03-01 00:00:00")
    unusable_staging = version_row(prefix, unusable, "staging", nil)
    unusable_run = export_run_row(prefix, unusable, unusable_staging)
    full_publication_row(prefix, unusable, 4, %{"source" => %{"run_id" => unusable_run}})

    # The frozen id belongs to another organization's version.
    foreign = organization_row(prefix)
    foreign_only = version_row(prefix, foreign, "published", "2026-02-01 00:00:00")
    full_publication_row(prefix, foreign, 1, %{"source" => %{"gtfs_version_id" => proven_old}})

    # Sequence 5 was served, but only the attempt for sequence 4 survives.
    collected = organization_row(prefix)
    collected_old = version_row(prefix, collected, "published", "2026-01-01 00:00:00")
    collected_newest = version_row(prefix, collected, "published", "2026-03-01 00:00:00")
    publication = full_publication_row(prefix, collected, 5, nil)

    attempt_row(prefix, publication, collected, 4, %{
      "source" => %{"gtfs_version_id" => collected_old}
    })

    # No publication: the newest published_at wins, then the newest inserted_at, then the
    # highest id; NULL is last. The ids are fixed so that the id tie-break alone would pick
    # the wrong version.
    ordering = organization_row(prefix)

    _never_stamped =
      version_row(prefix, ordering, "published", nil, inserted_at: "2026-06-01 00:00:00")

    _earlier =
      version_row(prefix, ordering, "published", "2026-02-01 00:00:00",
        id: "ffffffff-ffff-4fff-8fff-ffffffffffff",
        inserted_at: "2026-02-01 00:00:00"
      )

    chosen =
      version_row(prefix, ordering, "published", "2026-02-01 00:00:00",
        id: "00000000-0000-4000-8000-000000000001",
        inserted_at: "2026-02-02 00:00:00"
      )

    unusable_only = organization_row(prefix)
    _failed = version_row(prefix, unusable_only, "failed", nil)
    _importing = version_row(prefix, unusable_only, "importing", nil)

    %{
      proven: %{org: proven, old: proven_old, newer: proven_newer},
      frozen: %{org: frozen, old: frozen_old},
      unusable: %{org: unusable, newest: unusable_newest},
      foreign: %{org: foreign, only: foreign_only},
      collected: %{org: collected, newest: collected_newest},
      ordering: %{org: ordering, chosen: chosen},
      unusable_only: %{org: unusable_only}
    }
  end

  defp organization_row(prefix) do
    id = Ecto.UUID.generate()
    SQL.query!(Repo, "INSERT INTO #{q(prefix)}.organizations (id) VALUES ($1)", [dump(id)])
    id
  end

  defp version_row(prefix, organization, status, published_at, opts \\ []) do
    id = Keyword.get_lazy(opts, :id, &Ecto.UUID.generate/0)
    inserted_at = Keyword.get(opts, :inserted_at, "2026-01-01 00:00:00")

    SQL.query!(
      Repo,
      """
      INSERT INTO #{q(prefix)}.gtfs_versions
        (id, organization_id, publication_status, published_at, inserted_at)
      VALUES ($1, $2, $3, $4::text::timestamp, $5::text::timestamp)
      """,
      [dump(id), dump(organization), status, published_at, inserted_at]
    )

    id
  end

  defp export_run_row(prefix, organization, version) do
    id = Ecto.UUID.generate()

    SQL.query!(
      Repo,
      """
      INSERT INTO #{q(prefix)}.gtfs_export_runs (id, organization_id, gtfs_version_id)
      VALUES ($1, $2, $3)
      """,
      [dump(id), dump(organization), dump(version)]
    )

    id
  end

  # A full channel that served `sequence`; a snapshot also inserts that attempt.
  defp full_publication_row(prefix, organization, sequence, snapshot) do
    id = Ecto.UUID.generate()

    SQL.query!(
      Repo,
      """
      INSERT INTO #{q(prefix)}.feed_publications (id, organization_id, channel, manifest_sequence)
      VALUES ($1, $2, 'full', $3)
      """,
      [dump(id), dump(organization), sequence]
    )

    if snapshot, do: attempt_row(prefix, id, organization, sequence, snapshot)
    id
  end

  defp attempt_row(prefix, publication, organization, sequence, snapshot) do
    SQL.query!(
      Repo,
      """
      INSERT INTO #{q(prefix)}.feed_publication_attempts
        (id, publication_id, organization_id, sequence, private_snapshot)
      VALUES ($1, $2, $3, $4, $5)
      """,
      [dump(Ecto.UUID.generate()), dump(publication), dump(organization), sequence, snapshot]
    )
  end

  defp selection_row(prefix, organization) do
    %{rows: [[pointer, revision, sequence]]} =
      SQL.query!(
        Repo,
        """
        SELECT active_gtfs_version_id::text, active_gtfs_version_revision,
               active_full_publication_sequence
        FROM #{q(prefix)}.organizations WHERE id = $1
        """,
        [dump(organization)]
      )

    {pointer, revision, sequence}
  end

  defp version_count(prefix, organization) do
    %{rows: [[count]]} =
      SQL.query!(
        Repo,
        "SELECT count(*) FROM #{q(prefix)}.gtfs_versions WHERE organization_id = $1",
        [dump(organization)]
      )

    count
  end
end
