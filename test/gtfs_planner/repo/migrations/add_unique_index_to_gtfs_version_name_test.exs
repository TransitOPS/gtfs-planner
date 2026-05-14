defmodule GtfsPlanner.Repo.Migrations.AddUniqueIndexToGtfsVersionNameTest do
  use GtfsPlanner.DataCase, async: false

  import GtfsPlanner.OrganizationsFixtures

  Code.require_file(
    Path.expand(
      "../../../../priv/repo/migrations/20260513221139_add_unique_index_to_gtfs_version_name.exs",
      __DIR__
    )
  )

  alias GtfsPlanner.Repo.Migrations.AddUniqueIndexToGtfsVersionName, as: Migration

  setup do
    Ecto.Adapters.SQL.query!(
      Repo,
      "DROP INDEX IF EXISTS gtfs_versions_organization_id_name_index",
      []
    )

    :ok
  end

  describe "rename_duplicates/0" do
    test "keeps the row with the most recent updated_at and renames the rest" do
      org = organization_fixture()
      name = "Duplicate Name"

      kept_id = insert_version(org.id, name, ~U[2026-03-01 00:00:00.000000Z])
      _losing_id_1 = insert_version(org.id, name, ~U[2026-02-15 00:00:00.000000Z])
      _losing_id_2 = insert_version(org.id, name, ~U[2026-01-01 00:00:00.000000Z])

      Migration.rename_duplicates()

      rows = fetch_versions(org.id, like: name <> "%")
      kept = Enum.find(rows, &(&1.id == kept_id))
      renamed = Enum.reject(rows, &(&1.id == kept_id))

      assert kept.name == name

      assert Enum.count(renamed) == 2

      for r <- renamed do
        assert r.name == "#{name} (#{Ecto.UUID.cast!(r.id)})"
      end
    end

    test "leaves rows alone when no duplicates exist" do
      org = organization_fixture()
      id = insert_version(org.id, "Unique Name", ~U[2026-03-01 00:00:00.000000Z])

      Migration.rename_duplicates()

      [row] = fetch_versions(org.id, like: "Unique%")
      assert row.id == id
      assert row.name == "Unique Name"
    end

    test "scopes deduplication per organization" do
      org_a = organization_fixture()
      org_b = organization_fixture()
      name = "Shared Name"

      id_a = insert_version(org_a.id, name, ~U[2026-03-01 00:00:00.000000Z])
      id_b = insert_version(org_b.id, name, ~U[2026-03-01 00:00:00.000000Z])

      Migration.rename_duplicates()

      [row_a] = fetch_versions(org_a.id, like: name)
      [row_b] = fetch_versions(org_b.id, like: name)

      assert row_a.id == id_a
      assert row_a.name == name
      assert row_b.id == id_b
      assert row_b.name == name
    end

    test "renamed names stay within the 255-char column limit" do
      org = organization_fixture()
      long_name = String.duplicate("a", 255)

      _kept = insert_version(org.id, long_name, ~U[2026-03-01 00:00:00.000000Z])
      _losing = insert_version(org.id, long_name, ~U[2026-02-15 00:00:00.000000Z])

      Migration.rename_duplicates()

      renamed = fetch_versions(org.id, like: String.duplicate("a", 200) <> "%")

      for r <- renamed do
        assert String.length(r.name) <= 255
      end
    end
  end

  describe "verify_no_remaining_duplicates/0" do
    test "raises when duplicates still exist" do
      org = organization_fixture()
      insert_version(org.id, "Same", ~U[2026-03-01 00:00:00.000000Z])
      insert_version(org.id, "Same", ~U[2026-02-15 00:00:00.000000Z])

      assert_raise RuntimeError, ~r/Dedup did not eliminate all duplicates/, fn ->
        Migration.verify_no_remaining_duplicates()
      end
    end

    test "returns :ok when no duplicates exist" do
      org = organization_fixture()
      insert_version(org.id, "Solo", ~U[2026-03-01 00:00:00.000000Z])

      assert Migration.verify_no_remaining_duplicates() == :ok
    end
  end

  defp insert_version(org_id, name, ts) do
    id = Ecto.UUID.bingenerate()

    Ecto.Adapters.SQL.query!(
      Repo,
      """
      INSERT INTO gtfs_versions (id, organization_id, name, inserted_at, updated_at)
      VALUES ($1, $2, $3, $4, $4)
      """,
      [id, Ecto.UUID.dump!(org_id), name, ts]
    )

    Ecto.UUID.cast!(id)
  end

  defp fetch_versions(org_id, like: pattern) do
    %{rows: rows} =
      Ecto.Adapters.SQL.query!(
        Repo,
        """
        SELECT id, name FROM gtfs_versions
        WHERE organization_id = $1 AND name LIKE $2
        ORDER BY inserted_at
        """,
        [Ecto.UUID.dump!(org_id), pattern]
      )

    Enum.map(rows, fn [id, name] -> %{id: Ecto.UUID.cast!(id), name: name} end)
  end
end
