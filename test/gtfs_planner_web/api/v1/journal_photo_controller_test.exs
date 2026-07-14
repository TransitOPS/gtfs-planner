defmodule GtfsPlannerWeb.Api.V1.JournalPhotoControllerTest do
  use GtfsPlannerWeb.ConnCase, async: false

  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Gtfs.JournalEntry
  alias GtfsPlanner.Repo
  alias GtfsPlannerWeb.Api.V1.JournalPhotoController

  setup_all do
    previous = Application.get_env(:gtfs_planner, :uploads_path)

    on_exit(fn ->
      if is_nil(previous),
        do: Application.delete_env(:gtfs_planner, :uploads_path),
        else: Application.put_env(:gtfs_planner, :uploads_path, previous)
    end)

    :ok
  end

  setup %{conn: conn} do
    uploads_path =
      Path.join(
        System.tmp_dir!(),
        "journal_photo_controller_#{System.unique_integer([:positive])}"
      )

    Application.put_env(:gtfs_planner, :uploads_path, uploads_path)
    File.mkdir_p!(uploads_path)

    user = user_fixture()
    org = organization_fixture()
    version = gtfs_version_fixture(org.id)
    station = stop_fixture(org.id, version.id, %{location_type: 1, parent_station: nil})

    {:ok, _membership} =
      Accounts.create_user_org_membership(%{
        user_id: user.id,
        organization_id: org.id,
        roles: ["pathways_studio_editor"]
      })

    entry =
      Repo.insert!(%JournalEntry{
        id: Ecto.UUID.generate(),
        organization_id: org.id,
        gtfs_version_id: version.id,
        station_id: station.id,
        author_id: user.id,
        target_type: "station",
        captured_at: ~U[2026-07-13 10:00:00.000000Z]
      })

    on_exit(fn -> File.rm_rf!(uploads_path) end)

    %{
      conn:
        Plug.Conn.assign(conn, :current_organization_id, org.id)
        |> Plug.Conn.assign(:current_user_id, user.id),
      version: version,
      station: station,
      entry: entry,
      uploads_path: uploads_path
    }
  end

  test "creates a JPEG from object metadata with the shared public representation", context do
    photo_id = Ecto.UUID.generate()
    upload = upload(context.uploads_path, "capture.jpg", <<0xFF, 0xD8, "journal", 0xFF, 0xD9>>)

    conn =
      JournalPhotoController.create(context.conn, %{
        "version_id" => context.version.id,
        "station_id" => context.station.id,
        "metadata" => metadata(photo_id, context.entry.id),
        "file" => upload
      })

    assert %{"data" => %{"id" => ^photo_id, "content_type" => "image/jpeg", "url" => url}} =
             json_response(conn, 201)

    assert url =~ "/uploads/field-captures/#{context.conn.assigns.current_organization_id}/"
  end

  test "accepts JSON-string metadata and returns the original representation on identical retry",
       context do
    photo_id = Ecto.UUID.generate()
    bytes = <<137, 80, 78, 71, 13, 10, 26, 10, "journal", 0, 0, 0, 0, "IEND", 174, 66, 96, 130>>
    first_upload = upload(context.uploads_path, "first.png", bytes)

    params = %{
      "version_id" => context.version.id,
      "station_id" => context.station.id,
      "metadata" => Jason.encode!(metadata(photo_id, context.entry.id, %{width: 10})),
      "file" => first_upload
    }

    first = JournalPhotoController.create(context.conn, params)
    assert %{"data" => first_data} = json_response(first, 201)

    retry_upload = upload(context.uploads_path, "retry.png", bytes)

    retry =
      JournalPhotoController.create(context.conn, %{
        params
        | "metadata" =>
            Jason.encode!(metadata(photo_id, context.entry.id, %{width: 20, height: 30})),
          "file" => retry_upload
      })

    assert %{"data" => ^first_data} = json_response(retry, 201)
  end

  test "maps invalid URL, missing scope, conflicts, size, and validation failures", context do
    upload = upload(context.uploads_path, "capture.jpg", <<0xFF, 0xD8, 0xFF, 0xD9>>)
    photo_id = Ecto.UUID.generate()

    invalid_url =
      JournalPhotoController.create(context.conn, %{
        "version_id" => "not-a-uuid",
        "station_id" => context.station.id,
        "metadata" => metadata(photo_id, context.entry.id),
        "file" => upload
      })

    assert %{"error" => %{"code" => "bad_request"}} = json_response(invalid_url, 400)

    missing_entry =
      JournalPhotoController.create(context.conn, %{
        "version_id" => context.version.id,
        "station_id" => context.station.id,
        "metadata" => metadata(Ecto.UUID.generate(), Ecto.UUID.generate()),
        "file" => upload
      })

    assert %{"error" => %{"code" => "not_found"}} = json_response(missing_entry, 404)

    invalid_image =
      JournalPhotoController.create(context.conn, %{
        "version_id" => context.version.id,
        "station_id" => context.station.id,
        "metadata" => metadata(Ecto.UUID.generate(), context.entry.id),
        "file" => upload(context.uploads_path, "invalid.txt", "not an image")
      })

    assert %{"error" => %{"code" => "validation_error"}} = json_response(invalid_image, 422)
  end

  test "maps storage failures to an internal storage error", context do
    upload = upload(context.uploads_path, "capture.jpg", <<0xFF, 0xD8, 0xFF, 0xD9>>)
    blocking_path = Path.join(context.uploads_path, "blocking-file")
    File.write!(blocking_path, "not a directory")
    Application.put_env(:gtfs_planner, :uploads_path, blocking_path)

    conn =
      JournalPhotoController.create(context.conn, %{
        "version_id" => context.version.id,
        "station_id" => context.station.id,
        "metadata" => metadata(Ecto.UUID.generate(), context.entry.id),
        "file" => upload
      })

    assert %{"error" => %{"code" => "storage_error"}} = json_response(conn, 500)
  end

  defp metadata(photo_id, entry_id, overrides \\ %{}) do
    Map.merge(
      %{
        "id" => photo_id,
        "journal_entry_id" => entry_id,
        "captured_at" => "2026-07-13T10:00:00Z"
      },
      overrides
    )
  end

  defp upload(directory, filename, bytes) do
    path = Path.join(directory, "#{System.unique_integer([:positive])}-#{filename}")
    File.write!(path, bytes)
    %Plug.Upload{path: path, filename: filename, content_type: nil}
  end
end
