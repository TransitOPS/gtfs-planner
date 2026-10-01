defmodule GtfsPlanner.Gtfs.StationJournal.AuthorizationTest do
  use GtfsPlannerWeb.ConnCase, async: false

  import Ecto.Query
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.{JournalEntry, JournalPhoto}
  alias GtfsPlanner.Gtfs.StationJournal.Scope
  alias GtfsPlanner.Repo
  alias GtfsPlannerWeb.Api.V1.{JournalPhotoController, SyncController}

  @captured_at "2026-07-13T12:00:00.123456Z"
  @jpeg <<0xFF, 0xD8, "journal-photo", 0xFF, 0xD9>>

  setup do
    previous_uploads_path = Application.get_env(:gtfs_planner, :uploads_path)

    root =
      Path.join(
        System.tmp_dir!(),
        "station_journal_authorization_#{System.unique_integer([:positive])}"
      )

    Application.put_env(:gtfs_planner, :uploads_path, root)

    on_exit(fn ->
      File.rm_rf!(root)

      if is_nil(previous_uploads_path),
        do: Application.delete_env(:gtfs_planner, :uploads_path),
        else: Application.put_env(:gtfs_planner, :uploads_path, previous_uploads_path)
    end)

    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)

    station =
      stop_fixture(organization.id, version.id,
        stop_id: "station_#{System.unique_integer([:positive])}",
        location_type: 1
      )

    author = user_fixture()
    membership = organization_membership_fixture(author, organization)

    scope = %Scope{
      organization_id: organization.id,
      gtfs_version_id: version.id,
      station_id: station.id,
      station_stop_id: station.stop_id,
      actor_id: author.id
    }

    entry_id = Ecto.UUID.generate()

    %{synced_count: 1, errors: []} =
      Gtfs.sync_journal_entries(scope, [entry_attrs(entry_id, "original")])

    %{
      root: root,
      organization: organization,
      version: version,
      station: station,
      author: author,
      membership: membership,
      scope: scope,
      entry_id: entry_id
    }
  end

  describe "Gtfs.sync_journal_entries/2" do
    test "refuses new entries from a deactivated author and inserts nothing", context do
      deactivate_membership_fixture(context.membership)
      first_id = Ecto.UUID.generate()
      second_id = Ecto.UUID.generate()

      result =
        Gtfs.sync_journal_entries(context.scope, [
          entry_attrs(first_id, "first"),
          entry_attrs(second_id, "second")
        ])

      assert result == %{
               synced_count: 0,
               errors: [
                 %{id: first_id, code: :forbidden},
                 %{id: second_id, code: :forbidden}
               ]
             }

      assert journal_ids(context.station) == [context.entry_id]
    end

    test "refuses an update from a deactivated author and keeps the stored body", context do
      deactivate_membership_fixture(context.membership)

      result =
        Gtfs.sync_journal_entries(context.scope, [entry_attrs(context.entry_id, "rewritten")])

      assert result == %{
               synced_count: 0,
               errors: [%{id: context.entry_id, code: :forbidden}]
             }

      assert Repo.get!(JournalEntry, context.entry_id).body == "original"
    end

    test "refuses an author who is an editor only in another organization", context do
      outsider = editor_fixture(organization_fixture())
      outside_scope = %{context.scope | actor_id: outsider.id}
      new_id = Ecto.UUID.generate()

      result = Gtfs.sync_journal_entries(outside_scope, [entry_attrs(new_id, "outsider")])

      assert result == %{synced_count: 0, errors: [%{id: new_id, code: :forbidden}]}
      assert journal_ids(context.station) == [context.entry_id]
    end
  end

  describe "Gtfs.create_journal_photo/3" do
    test "refuses a deactivated author with no photo row and no stored file", context do
      deactivate_membership_fixture(context.membership)
      photo_id = Ecto.UUID.generate()

      result =
        Gtfs.create_journal_photo(
          context.scope,
          photo_attrs(photo_id, context.entry_id),
          upload(context.root, "capture.jpg")
        )

      assert result == {:error, :forbidden}
      assert Repo.get(JournalPhoto, photo_id) == nil
      assert stored_files(context.root) == []
    end
  end

  describe "Gtfs.close_journal_entry/2 and reopen_journal_entry/2" do
    test "refuses closing an entry for a deactivated actor and leaves it open", context do
      deactivate_membership_fixture(context.membership)

      assert Gtfs.close_journal_entry(context.scope, context.entry_id) == {:error, :forbidden}

      assert Repo.get!(JournalEntry, context.entry_id).closed_at == nil
    end

    test "refuses reopening an entry for a deactivated actor and leaves it closed", context do
      {:ok, _closed} = Gtfs.close_journal_entry(context.scope, context.entry_id)
      closed = Repo.get!(JournalEntry, context.entry_id)
      deactivate_membership_fixture(context.membership)

      assert Gtfs.reopen_journal_entry(context.scope, context.entry_id) == {:error, :forbidden}

      assert Repo.get!(JournalEntry, context.entry_id) == closed
    end
  end

  describe "companion API controllers" do
    test "sync reports forbidden for each journal entry of a deactivated author", context do
      deactivate_membership_fixture(context.membership)
      new_id = Ecto.UUID.generate()

      conn =
        context.conn
        |> assign(:current_organization_id, context.organization.id)
        |> assign(:current_user_id, context.author.id)
        |> assign(:current_user, context.author)

      conn =
        SyncController.create(conn, %{
          "version_id" => context.version.id,
          "station_id" => context.station.id,
          "pathways" => [],
          "journal_entries" => [
            %{"id" => new_id, "target_type" => "station", "captured_at" => @captured_at}
          ]
        })

      assert %{"data" => %{"journal_synced_count" => 0, "errors" => [error]}} =
               json_response(conn, 200)

      assert error == %{
               "id" => new_id,
               "code" => "forbidden",
               "message" => "Editor access was revoked."
             }

      assert journal_ids(context.station) == [context.entry_id]
    end

    test "photo upload returns 403 for a deactivated author and stores nothing", context do
      deactivate_membership_fixture(context.membership)
      photo_id = Ecto.UUID.generate()
      upload = upload(context.root, "capture.jpg")

      conn =
        context.conn
        |> assign(:current_organization_id, context.organization.id)
        |> assign(:current_user_id, context.author.id)

      conn =
        JournalPhotoController.create(conn, %{
          "version_id" => context.version.id,
          "station_id" => context.station.id,
          "metadata" => photo_attrs(photo_id, context.entry_id),
          "file" => %Plug.Upload{
            path: upload.path,
            filename: upload.filename,
            content_type: upload.content_type
          }
        })

      assert json_response(conn, 403) == %{"error" => %{"code" => "forbidden"}}
      assert Repo.get(JournalPhoto, photo_id) == nil
      assert stored_files(context.root) == []
    end
  end

  defp entry_attrs(id, body) do
    %{id: id, target_type: "station", body: body, captured_at: @captured_at}
  end

  defp photo_attrs(photo_id, entry_id) do
    %{"id" => photo_id, "journal_entry_id" => entry_id, "captured_at" => "2026-07-13T10:00:00Z"}
  end

  defp journal_ids(station) do
    Repo.all(
      from(entry in JournalEntry, where: entry.station_id == ^station.id, select: entry.id)
    )
  end

  defp upload(root, filename) do
    path = Path.join([root, "incoming", "#{System.unique_integer([:positive])}-#{filename}"])
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, @jpeg)
    %{path: path, filename: filename, content_type: nil}
  end

  defp stored_files(root) do
    Path.wildcard(Path.join([root, "field-captures", "**", "*.{jpg,tmp}"]))
  end
end
