defmodule GtfsPlanner.Gtfs.FeedSettings.FeedInfoTest do
  use GtfsPlanner.DataCase

  import Ecto.Query
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Gtfs.AuditContext
  alias GtfsPlanner.Gtfs.Export
  alias GtfsPlanner.Gtfs.FeedInfo
  alias GtfsPlanner.Gtfs.FeedSettings
  alias GtfsPlanner.Repo
  alias GtfsPlanner.Versions

  @url_message "must be a full web address starting with https:// or http://"

  @valid_attrs %{
    feed_publisher_name: "Metro Transit",
    feed_publisher_url: "https://metro.example",
    feed_lang: "en",
    default_lang: "es",
    feed_start_date: ~D[2026-01-01],
    feed_end_date: ~D[2026-06-30],
    feed_version: "2026-spring",
    feed_contact_email: "data@metro.example",
    feed_contact_url: "https://metro.example/contact"
  }

  setup do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    actor = editor_fixture(organization)

    %{
      organization: organization,
      version: version,
      actor: actor,
      audit: audit_context(organization, version, actor)
    }
  end

  describe "get_feed_info/2" do
    test "returns nil until the version has feed info, and only its own version's row", context do
      assert FeedSettings.get_feed_info(context.organization.id, context.version.id) == nil

      {:ok, saved} = FeedSettings.save_feed_info(context.audit, @valid_attrs, nil)
      other_version = gtfs_version_fixture(context.organization.id)
      other_organization = organization_fixture()

      assert %FeedInfo{id: saved_id} =
               FeedSettings.get_feed_info(context.organization.id, context.version.id)

      assert saved_id == saved.id
      assert FeedSettings.get_feed_info(context.organization.id, other_version.id) == nil

      assert FeedSettings.get_feed_info(other_organization.id, context.version.id) == nil
    end
  end

  describe "save_feed_info/3" do
    test "the first save with a nil token inserts one scoped row", context do
      assert {:ok, %FeedInfo{} = saved} =
               FeedSettings.save_feed_info(context.audit, @valid_attrs, nil)

      assert saved.organization_id == context.organization.id
      assert saved.gtfs_version_id == context.version.id
      assert saved.feed_publisher_name == "Metro Transit"
      assert saved.feed_lang == "en"
      assert saved.feed_start_date == ~D[2026-01-01]
      assert saved.feed_end_date == ~D[2026-06-30]
      assert saved.feed_version == "2026-spring"

      assert row_count(context.organization) == 1
    end

    test "a second save with the returned updated_at updates that row", context do
      {:ok, saved} = FeedSettings.save_feed_info(context.audit, @valid_attrs, nil)

      attrs = Map.put(@valid_attrs, :feed_publisher_name, "Metro Transit Authority")

      assert {:ok, %FeedInfo{} = updated} =
               FeedSettings.save_feed_info(context.audit, attrs, saved.updated_at)

      assert updated.id == saved.id
      assert updated.feed_publisher_name == "Metro Transit Authority"
      assert row_count(context.organization) == 1
    end

    test "an older updated_at returns :stale and leaves the row unchanged", context do
      {:ok, saved} = FeedSettings.save_feed_info(context.audit, @valid_attrs, nil)
      stale_token = DateTime.add(saved.updated_at, -1, :second)

      attrs = Map.put(@valid_attrs, :feed_publisher_name, "Rewrite")

      assert {:error, :stale} = FeedSettings.save_feed_info(context.audit, attrs, stale_token)

      assert Repo.get!(FeedInfo, saved.id).feed_publisher_name == "Metro Transit"
      assert row_count(context.organization) == 1
    end

    test "a newer updated_at returns :stale and leaves the row unchanged", context do
      {:ok, saved} = FeedSettings.save_feed_info(context.audit, @valid_attrs, nil)
      future_token = DateTime.add(saved.updated_at, 60, :second)

      attrs = Map.put(@valid_attrs, :feed_publisher_name, "Rewrite")

      assert {:error, :stale} = FeedSettings.save_feed_info(context.audit, attrs, future_token)

      assert Repo.get!(FeedInfo, saved.id).feed_publisher_name == "Metro Transit"
      assert row_count(context.organization) == 1
    end

    test "a nil token against an existing row returns :stale and writes nothing", context do
      {:ok, saved} = FeedSettings.save_feed_info(context.audit, @valid_attrs, nil)

      attrs = Map.put(@valid_attrs, :feed_publisher_name, "Rewrite")

      assert {:error, :stale} = FeedSettings.save_feed_info(context.audit, attrs, nil)

      assert Repo.get!(FeedInfo, saved.id).feed_publisher_name == "Metro Transit"
      assert row_count(context.organization) == 1
    end

    test "a token without a row returns :stale and inserts nothing", context do
      empty_version = gtfs_version_fixture(context.organization.id)
      empty_audit = audit_context(context.organization, empty_version, context.actor)

      assert {:error, :stale} =
               FeedSettings.save_feed_info(empty_audit, @valid_attrs, DateTime.utc_now())

      assert FeedSettings.get_feed_info(context.organization.id, empty_version.id) == nil
      assert row_count(context.organization) == 0
    end

    test "scope fields in the attrs never move the row out of its version", context do
      other_organization = organization_fixture()
      other_version = gtfs_version_fixture(other_organization.id)

      attrs =
        Map.merge(@valid_attrs, %{
          organization_id: other_organization.id,
          gtfs_version_id: other_version.id
        })

      assert {:ok, %FeedInfo{} = saved} = FeedSettings.save_feed_info(context.audit, attrs, nil)

      assert saved.organization_id == context.organization.id
      assert saved.gtfs_version_id == context.version.id
      assert row_count(context.organization) == 1
      assert row_count(other_organization) == 0
    end

    test "an invalid value returns the changeset and writes nothing", context do
      attrs = Map.put(@valid_attrs, :feed_publisher_url, "www.example.com")

      assert {:error, %Ecto.Changeset{} = changeset} =
               FeedSettings.save_feed_info(context.audit, attrs, nil)

      assert errors_on(changeset)[:feed_publisher_url] == [@url_message]
      assert row_count(context.organization) == 0
    end

    test "an invalid value on an update keeps the stored row", context do
      {:ok, saved} = FeedSettings.save_feed_info(context.audit, @valid_attrs, nil)
      attrs = Map.put(@valid_attrs, :feed_publisher_url, "www.example.com")

      assert {:error, %Ecto.Changeset{}} =
               FeedSettings.save_feed_info(context.audit, attrs, saved.updated_at)

      assert Repo.get!(FeedInfo, saved.id).feed_publisher_url == "https://metro.example"
      assert row_count(context.organization) == 1
    end

    test "a duplicate first insert is refused by the version's unique index", context do
      {:ok, _saved} = FeedSettings.save_feed_info(context.audit, @valid_attrs, nil)

      # The save's insert branch inserts exactly this changeset when its own load of the
      # row sees nothing, which is how a loser of a concurrent first insert gets here. The
      # savepoint matches the save's insert, so the expected violation leaves the sandbox
      # transaction usable for the row-count assertions below.
      duplicate =
        %FeedInfo{
          organization_id: context.organization.id,
          gtfs_version_id: context.version.id
        }
        |> FeedInfo.editor_changeset(@valid_attrs)
        |> Repo.insert(mode: :savepoint)

      assert {:error, %Ecto.Changeset{errors: errors}} = duplicate

      assert Enum.any?(errors, fn
               {_field, {_message, opts}} when is_list(opts) -> opts[:constraint] == :unique
               _error -> false
             end)

      assert row_count(context.organization) == 1
    end
  end

  describe "save_feed_info/3 scope and authority" do
    test "a foreign, unpublished, random or malformed version returns :not_found", context do
      other_organization = organization_fixture()
      other_version = gtfs_version_fixture(other_organization.id)

      {:ok, staging} =
        Versions.create_staging_gtfs_version(context.organization.id, %{name: "Staging"})

      assert {:error, :not_found} =
               FeedSettings.save_feed_info(
                 audit_context(context.organization, other_version, context.actor),
                 @valid_attrs,
                 nil
               )

      assert {:error, :not_found} =
               FeedSettings.save_feed_info(
                 audit_context(context.organization, staging, context.actor),
                 @valid_attrs,
                 nil
               )

      assert {:error, :not_found} =
               FeedSettings.save_feed_info(
                 audit_context(context.organization, %{id: Ecto.UUID.generate()}, context.actor),
                 @valid_attrs,
                 nil
               )

      assert {:error, :not_found} =
               FeedSettings.save_feed_info(
                 audit_context(context.organization, %{id: "not-a-uuid"}, context.actor),
                 @valid_attrs,
                 nil
               )

      assert row_count(context.organization) == 0
      assert row_count(other_organization) == 0
    end

    test "an actor from the other organization cannot write this version", context do
      other_organization = organization_fixture()
      other_actor = editor_fixture(other_organization)

      assert {:error, :not_found} =
               FeedSettings.save_feed_info(
                 audit_context(other_organization, context.version, other_actor),
                 @valid_attrs,
                 nil
               )

      assert row_count(context.organization) == 0
    end

    test "a deactivated membership and a membership without the editor role are forbidden",
         context do
      deactivated_actor = user_fixture()
      membership = organization_membership_fixture(deactivated_actor, context.organization)
      deactivate_membership_fixture(membership)

      assert {:error, :forbidden} =
               FeedSettings.save_feed_info(
                 audit_context(context.organization, context.version, deactivated_actor),
                 @valid_attrs,
                 nil
               )

      viewer = user_fixture()
      organization_membership_fixture(viewer, context.organization, [])

      assert {:error, :forbidden} =
               FeedSettings.save_feed_info(
                 audit_context(context.organization, context.version, viewer),
                 @valid_attrs,
                 nil
               )

      assert {:error, :forbidden} =
               FeedSettings.save_feed_info(
                 %{context.audit | actor_id: Ecto.UUID.generate()},
                 @valid_attrs,
                 nil
               )

      assert row_count(context.organization) == 0
    end
  end

  describe "export round trip" do
    test "a saved row reaches feed_info.txt with the stored values", context do
      attrs = Map.put(@valid_attrs, :feed_publisher_name, "Metro Transit Authority")

      assert {:ok, saved} = FeedSettings.save_feed_info(context.audit, attrs, nil)

      assert {:ok, zip_binary, []} =
               Export.build_zip(context.organization.id, context.version.id, :full)

      {:ok, files} = :zip.unzip(zip_binary, [:memory])
      {_name, content} = Enum.find(files, fn {name, _} -> to_string(name) == "feed_info.txt" end)

      [header, row | _rest] = content |> to_string() |> String.split("\n", trim: true)

      assert String.split(header, ",") == [
               "feed_publisher_name",
               "feed_publisher_url",
               "feed_lang",
               "default_lang",
               "feed_start_date",
               "feed_end_date",
               "feed_version",
               "feed_contact_email",
               "feed_contact_url"
             ]

      fields = String.split(header, ",") |> Enum.zip(String.split(row, ",")) |> Map.new()

      assert fields["feed_publisher_name"] == "Metro Transit Authority"
      assert fields["feed_publisher_url"] == "https://metro.example"
      assert fields["feed_lang"] == "en"
      assert fields["default_lang"] == "es"
      assert fields["feed_start_date"] == "20260101"
      assert fields["feed_end_date"] == "20260630"
      assert fields["feed_version"] == "2026-spring"
      assert fields["feed_contact_email"] == "data@metro.example"
      assert fields["feed_contact_url"] == "https://metro.example/contact"

      assert saved.feed_publisher_name == "Metro Transit Authority"
    end
  end

  defp row_count(organization) do
    Repo.aggregate(
      from(f in FeedInfo, where: f.organization_id == ^organization.id),
      :count
    )
  end

  defp audit_context(organization, version, actor) do
    %AuditContext{
      organization_id: organization.id,
      gtfs_version_id: version.id,
      station_stop_id: nil,
      actor_id: actor.id,
      actor_email: actor.email
    }
  end
end
