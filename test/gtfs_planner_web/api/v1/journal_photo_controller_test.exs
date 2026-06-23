defmodule GtfsPlannerWeb.Api.V1.JournalPhotoControllerTest do
  # async: false — uploads write under the global `:uploads_path` app env, which
  # another async test (UploadsPlugTest) mutates via Application.put_env. Running
  # serially keeps the storage directory stable for the duration of each test.
  use GtfsPlannerWeb.ConnCase, async: false

  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures
  import GtfsPlanner.GtfsFixtures

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.JournalPhoto
  alias GtfsPlanner.Repo

  # Pin the uploads directory to a unique path per test run so file writes are
  # isolated from other modules that mutate the global :uploads_path app env.
  setup do
    original = Application.get_env(:gtfs_planner, :uploads_path)

    path =
      Path.join(System.tmp_dir!(), "journal_photo_test_#{System.unique_integer([:positive])}")

    Application.put_env(:gtfs_planner, :uploads_path, path)

    on_exit(fn ->
      File.rm_rf!(path)
      Application.put_env(:gtfs_planner, :uploads_path, original)
    end)

    :ok
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp setup_user_with_org(_context) do
    user = user_fixture()
    org = organization_fixture()

    {:ok, _membership} =
      Accounts.create_user_org_membership(%{
        user_id: user.id,
        organization_id: org.id,
        roles: ["pathways_studio_editor"]
      })

    %{user: user, org: org}
  end

  defp authed_conn(conn, user) do
    token = Accounts.generate_api_session_token(user)

    conn
    |> put_req_header("accept", "application/json")
    |> put_req_header("authorization", "Bearer #{token}")
  end

  defp build_station(org_id, version_id) do
    stop_fixture(org_id, version_id, %{location_type: 1, parent_station: nil})
  end

  defp journal_entry_fixture(org, version, station, author, attrs \\ %{}) do
    base = %{
      "id" => Ecto.UUID.generate(),
      "organization_id" => org.id,
      "gtfs_version_id" => version.id,
      "station_id" => station.id,
      "author_id" => author.id,
      "target_type" => "station",
      "body" => "note",
      "captured_at" => "2026-06-20T10:00:00Z"
    }

    {:ok, entry} = Gtfs.upsert_journal_entry(Map.merge(base, attrs))
    entry
  end

  # Builds a %Plug.Upload{} backed by a temp file of the given bytes.
  defp upload_fixture(content, opts \\ []) do
    content_type = Keyword.get(opts, :content_type, "image/jpeg")
    filename = Keyword.get(opts, :filename, "photo.jpg")
    path = Path.join(System.tmp_dir!(), "upload_#{Ecto.UUID.generate()}")
    File.write!(path, content)
    %Plug.Upload{path: path, filename: filename, content_type: content_type}
  end

  defp photos_url(version_id, station_id),
    do: "/api/v1/versions/#{version_id}/stations/#{station_id}/journal-photos"

  # ---------------------------------------------------------------------------
  # POST .../journal-photos
  # ---------------------------------------------------------------------------

  describe "create/2" do
    setup [:setup_user_with_org]

    test "uploads a photo, creates the row + file, returns a static url", %{
      conn: conn,
      user: user,
      org: org
    } do
      version = gtfs_version_fixture(org.id)
      station = build_station(org.id, version.id)
      entry = journal_entry_fixture(org, version, station, user)

      photo_id = Ecto.UUID.generate()
      upload = upload_fixture("jpegbytes")

      payload = %{
        "file" => upload,
        "metadata" =>
          Jason.encode!(%{
            "id" => photo_id,
            "journal_entry_id" => entry.id,
            "captured_at" => "2026-06-20T10:05:00Z",
            "content_type" => "image/jpeg"
          })
      }

      conn = conn |> authed_conn(user) |> post(photos_url(version.id, station.id), payload)

      assert %{"data" => %{"photo" => photo}} = json_response(conn, 201)
      assert photo["id"] == photo_id
      assert photo["journal_entry_id"] == entry.id
      assert photo["content_type"] == "image/jpeg"
      assert String.contains?(photo["url"], "/uploads/field-captures/#{org.id}/")
      assert String.ends_with?(photo["url"], "#{photo_id}.jpg")

      row = Repo.get!(JournalPhoto, photo_id)
      assert row.journal_entry_id == entry.id
      assert row.filename == "#{photo_id}.jpg"
      assert row.byte_size == byte_size("jpegbytes")

      uploads_base = Application.get_env(:gtfs_planner, :uploads_path)

      dest =
        Path.join([uploads_base, "field-captures", org.id, station.stop_id, "#{photo_id}.jpg"])

      assert File.exists?(dest)
    end

    test "is idempotent on id (re-upload returns the same record)", %{
      conn: conn,
      user: user,
      org: org
    } do
      version = gtfs_version_fixture(org.id)
      station = build_station(org.id, version.id)
      entry = journal_entry_fixture(org, version, station, user)
      photo_id = Ecto.UUID.generate()

      payload = fn ->
        %{
          "file" => upload_fixture("bytes"),
          "metadata" =>
            Jason.encode!(%{
              "id" => photo_id,
              "journal_entry_id" => entry.id,
              "captured_at" => "2026-06-20T10:05:00Z",
              "content_type" => "image/jpeg"
            })
        }
      end

      conn |> authed_conn(user) |> post(photos_url(version.id, station.id), payload.())

      conn2 =
        build_conn() |> authed_conn(user) |> post(photos_url(version.id, station.id), payload.())

      assert %{"data" => %{"photo" => photo}} = json_response(conn2, 201)
      assert photo["id"] == photo_id
      assert Repo.aggregate(JournalPhoto, :count, :id) == 1
    end

    test "returns 404 for an entry not in the org", %{conn: conn, user: user, org: org} do
      version = gtfs_version_fixture(org.id)
      station = build_station(org.id, version.id)

      other_org = organization_fixture()
      other_version = gtfs_version_fixture(other_org.id)
      other_station = build_station(other_org.id, other_version.id)
      other_user = user_fixture()
      other_entry = journal_entry_fixture(other_org, other_version, other_station, other_user)

      payload = %{
        "file" => upload_fixture("bytes"),
        "metadata" =>
          Jason.encode!(%{
            "id" => Ecto.UUID.generate(),
            "journal_entry_id" => other_entry.id,
            "captured_at" => "2026-06-20T10:05:00Z",
            "content_type" => "image/jpeg"
          })
      }

      conn = conn |> authed_conn(user) |> post(photos_url(version.id, station.id), payload)

      assert %{"error" => %{"code" => "not_found"}} = json_response(conn, 404)
      assert Repo.aggregate(JournalPhoto, :count, :id) == 0
    end

    test "returns 422 for an unsupported content type", %{conn: conn, user: user, org: org} do
      version = gtfs_version_fixture(org.id)
      station = build_station(org.id, version.id)
      entry = journal_entry_fixture(org, version, station, user)

      payload = %{
        "file" => upload_fixture("gifbytes", content_type: "image/gif"),
        "metadata" =>
          Jason.encode!(%{
            "id" => Ecto.UUID.generate(),
            "journal_entry_id" => entry.id,
            "captured_at" => "2026-06-20T10:05:00Z",
            "content_type" => "image/gif"
          })
      }

      conn = conn |> authed_conn(user) |> post(photos_url(version.id, station.id), payload)

      assert %{"error" => %{"code" => "validation_error"}} = json_response(conn, 422)
      assert Repo.aggregate(JournalPhoto, :count, :id) == 0
    end

    test "an uploaded photo nests under its entry in the bundle", %{
      conn: conn,
      user: user,
      org: org
    } do
      version = gtfs_version_fixture(org.id)
      station = build_station(org.id, version.id)
      entry = journal_entry_fixture(org, version, station, user)
      photo_id = Ecto.UUID.generate()

      upload_payload = %{
        "file" => upload_fixture("bytes"),
        "metadata" =>
          Jason.encode!(%{
            "id" => photo_id,
            "journal_entry_id" => entry.id,
            "captured_at" => "2026-06-20T10:05:00Z",
            "content_type" => "image/jpeg"
          })
      }

      conn |> authed_conn(user) |> post(photos_url(version.id, station.id), upload_payload)

      bundle_conn =
        build_conn()
        |> authed_conn(user)
        |> get("/api/v1/versions/#{version.id}/stations/#{station.id}/bundle")

      assert %{"data" => %{"journal_entries" => [bundle_entry]}} = json_response(bundle_conn, 200)
      assert bundle_entry["id"] == entry.id
      assert [photo] = bundle_entry["photos"]
      assert photo["id"] == photo_id
      assert photo["content_type"] == "image/jpeg"
      assert String.ends_with?(photo["url"], "#{photo_id}.jpg")
    end
  end
end
