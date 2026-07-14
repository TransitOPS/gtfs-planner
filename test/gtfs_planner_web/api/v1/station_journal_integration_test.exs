defmodule GtfsPlannerWeb.Api.V1.StationJournalIntegrationTest do
  use GtfsPlannerWeb.ConnCase, async: false

  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Gtfs

  @password "valid user password 123456"

  setup_all do
    previous_uploads_path = Application.get_env(:gtfs_planner, :uploads_path)

    on_exit(fn ->
      if previous_uploads_path do
        Application.put_env(:gtfs_planner, :uploads_path, previous_uploads_path)
      else
        Application.delete_env(:gtfs_planner, :uploads_path)
      end
    end)

    :ok
  end

  setup do
    uploads_path =
      Path.join(
        System.tmp_dir!(),
        "station_journal_integration_#{System.unique_integer([:positive])}"
      )

    Application.put_env(:gtfs_planner, :uploads_path, uploads_path)
    File.mkdir_p!(uploads_path)

    on_exit(fn -> File.rm_rf!(uploads_path) end)

    %{uploads_path: uploads_path}
  end

  test "mobile consumer logs in, discovers, syncs, uploads, retries, and refreshes its bundle", %{
    conn: conn
  } do
    %{user: user, organization: organization, version: version, station: station} =
      editor_station_fixture()

    login = post(conn, "/api/v1/auth/login", %{"email" => user.email, "password" => @password})

    assert %{"data" => %{"token" => token, "organization_id" => organization_id}} =
             json_response(login, 200)

    assert organization_id == organization.id

    versions = get(api_conn(conn, token, organization_id), "/api/v1/versions")
    assert %{"data" => versions_data} = json_response(versions, 200)
    assert %{"id" => version_id} = Enum.find(versions_data, &(&1["id"] == version.id))

    stations =
      get(api_conn(conn, token, organization_id), "/api/v1/versions/#{version_id}/stations")

    assert %{"data" => stations_data} = json_response(stations, 200)
    assert %{"id" => station_id} = Enum.find(stations_data, &(&1["id"] == station.id))

    initial_bundle =
      get(api_conn(conn, token, organization_id), bundle_url(version_id, station_id))

    assert %{"data" => initial_data} = json_response(initial_bundle, 200)

    [node | _] = initial_data["stops"]
    [pathway | _] = initial_data["pathways"]
    level = Enum.find(initial_data["levels"], &is_binary(&1["stop_level_id"]))

    entries = [
      entry_payload("station"),
      entry_payload("node", %{"target_id" => node["id"]}),
      entry_payload("pathway", %{"target_id" => pathway["id"]}),
      entry_payload("pin", %{
        "stop_level_id" => level["stop_level_id"],
        "diagram_x" => 50.0,
        "diagram_y" => 40.0
      })
    ]

    sync =
      post(api_conn(conn, token, organization_id), sync_url(version_id, station_id), %{
        "pathways" => [],
        "journal_entries" => entries
      })

    assert %{"data" => %{"synced_count" => 0, "journal_synced_count" => 4}} =
             json_response(sync, 200)

    station_entry = Enum.find(entries, &(&1["target_type"] == "station"))
    photo_id = Ecto.UUID.generate()

    metadata = %{
      "id" => photo_id,
      "journal_entry_id" => station_entry["id"],
      "captured_at" => "2026-07-13T10:00:00Z",
      "width" => 1,
      "height" => 1
    }

    upload =
      post_multipart(
        api_conn(conn, token, organization_id),
        photo_url(version_id, station_id),
        metadata,
        jpeg()
      )

    assert %{"data" => %{"photo" => photo}} = json_response(upload, 201)

    assert photo == %{
             "id" => photo_id,
             "journal_entry_id" => station_entry["id"],
             "url" => photo["url"],
             "content_type" => "image/jpeg",
             "width" => 1,
             "height" => 1,
             "captured_at" => "2026-07-13T10:00:00.000000Z"
           }

    public_url = photo["url"]

    public_get = get(build_conn(), URI.parse(public_url).path)
    assert public_get.status == 200
    assert get_resp_header(public_get, "content-type") == ["image/jpeg"]
    assert get_resp_header(public_get, "cache-control") == ["public, max-age=31536000, immutable"]
    assert get_resp_header(public_get, "x-content-type-options") == ["nosniff"]
    assert public_get.resp_body == jpeg()

    refreshed = get(api_conn(conn, token, organization_id), bundle_url(version_id, station_id))
    assert %{"data" => refreshed_data} = json_response(refreshed, 200)

    station_json =
      expected_entry(station_entry, user.id, %{"target_id" => nil, "photos" => [photo]})

    node_entry = Enum.find(entries, &(&1["target_type"] == "node"))
    pathway_entry = Enum.find(entries, &(&1["target_type"] == "pathway"))
    pin_entry = Enum.find(entries, &(&1["target_type"] == "pin"))

    node_json = expected_entry(node_entry, user.id, %{"target_id" => node["id"]})

    pathway_json =
      expected_entry(pathway_entry, user.id, %{"target_id" => pathway["id"]})

    pin_json =
      expected_entry(pin_entry, user.id, %{
        "stop_level_id" => level["stop_level_id"],
        "diagram_coordinate" => %{"x" => 50.0, "y" => 40.0},
        "lat" => nil,
        "lon" => nil
      })

    assert refreshed_data["journal_entries"] == [station_json]

    assert Enum.find(refreshed_data["stops"], &(&1["id"] == node["id"]))[
             "journal_entries"
           ] == [node_json]

    assert Enum.find(refreshed_data["pathways"], &(&1["id"] == pathway["id"]))[
             "journal_entries"
           ] == [pathway_json]

    assert Enum.find(
             refreshed_data["levels"],
             &(&1["stop_level_id"] == level["stop_level_id"])
           )["journal_entries"] == [pin_json]

    assert Enum.sort(journal_ids(refreshed_data)) == Enum.sort(Enum.map(entries, & &1["id"]))

    retry_sync =
      post(api_conn(conn, token, organization_id), sync_url(version_id, station_id), %{
        "pathways" => [],
        "journal_entries" => entries
      })

    assert %{"data" => %{"journal_synced_count" => 4}} = json_response(retry_sync, 200)

    retry_upload =
      post_multipart(
        api_conn(conn, token, organization_id),
        photo_url(version_id, station_id),
        Map.merge(metadata, %{"width" => 999, "height" => 999}),
        jpeg()
      )

    assert %{"data" => %{"photo" => ^photo}} = json_response(retry_upload, 201)

    retried_bundle =
      get(api_conn(conn, token, organization_id), bundle_url(version_id, station_id))

    assert %{"data" => retried_data} = json_response(retried_bundle, 200)

    assert retried_data["journal_entries"] == [station_json]

    assert Enum.find(retried_data["stops"], &(&1["id"] == node["id"]))[
             "journal_entries"
           ] == [node_json]

    assert Enum.find(retried_data["pathways"], &(&1["id"] == pathway["id"]))[
             "journal_entries"
           ] == [pathway_json]

    assert Enum.find(
             retried_data["levels"],
             &(&1["stop_level_id"] == level["stop_level_id"])
           )["journal_entries"] == [pin_json]

    assert Enum.sort(journal_ids(retried_data)) ==
             Enum.sort(Enum.map(entries, & &1["id"]))
  end

  test "a viewer can read the selected organization bundle but cannot sync or upload", %{
    conn: conn
  } do
    %{organization: organization, version: version, station: station} = editor_station_fixture()
    viewer = user_fixture()

    {:ok, _membership} =
      Accounts.create_user_org_membership(%{
        user_id: viewer.id,
        organization_id: organization.id,
        roles: []
      })

    login = post(conn, "/api/v1/auth/login", %{"email" => viewer.email, "password" => @password})
    assert %{"data" => %{"token" => token}} = json_response(login, 200)

    bundle = get(api_conn(conn, token, organization.id), bundle_url(version.id, station.id))
    assert %{"data" => _} = json_response(bundle, 200)

    sync =
      post(api_conn(conn, token, organization.id), sync_url(version.id, station.id), %{
        "pathways" => []
      })

    assert %{"error" => %{"code" => "forbidden"}} = json_response(sync, 403)

    upload =
      post_multipart(
        api_conn(conn, token, organization.id),
        photo_url(version.id, station.id),
        %{},
        jpeg()
      )

    assert %{"error" => %{"code" => "forbidden"}} = json_response(upload, 403)
  end

  test "a multi-organization user selects the intended membership for reads and writes", %{
    conn: conn
  } do
    user = user_fixture()
    first_organization = organization_fixture()
    second_organization = organization_fixture()

    {:ok, _} =
      Accounts.create_user_org_membership(%{
        user_id: user.id,
        organization_id: first_organization.id,
        roles: []
      })

    {:ok, _} =
      Accounts.create_user_org_membership(%{
        user_id: user.id,
        organization_id: second_organization.id,
        roles: ["pathways_studio_editor"]
      })

    version = gtfs_version_fixture(second_organization.id)
    %{station: station} = station_fixture(second_organization.id, version.id)

    login = post(conn, "/api/v1/auth/login", %{"email" => user.email, "password" => @password})
    assert %{"data" => %{"token" => token}} = json_response(login, 200)

    no_selection = get(api_conn(conn, token), "/api/v1/versions")
    assert %{"error" => %{"code" => "organization_required"}} = json_response(no_selection, 403)

    selected_versions = get(api_conn(conn, token, second_organization.id), "/api/v1/versions")
    assert %{"data" => versions} = json_response(selected_versions, 200)
    assert Enum.any?(versions, &(&1["id"] == version.id))

    sync =
      post(api_conn(conn, token, second_organization.id), sync_url(version.id, station.id), %{
        "pathways" => [],
        "journal_entries" => [entry_payload("station")]
      })

    assert %{"data" => %{"journal_synced_count" => 1}} = json_response(sync, 200)
  end

  defp editor_station_fixture do
    user = user_fixture()
    organization = organization_fixture()

    {:ok, _membership} =
      Accounts.create_user_org_membership(%{
        user_id: user.id,
        organization_id: organization.id,
        roles: ["pathways_studio_editor"]
      })

    version = gtfs_version_fixture(organization.id)
    station_data = station_fixture(organization.id, version.id)

    %{user: user, organization: organization, version: version, station: station_data.station}
  end

  defp station_fixture(organization_id, version_id) do
    level = level_fixture(organization_id, version_id)
    station = stop_fixture(organization_id, version_id, %{location_type: 1, parent_station: nil})

    node =
      stop_fixture(organization_id, version_id, %{
        parent_station: station.stop_id,
        level_id: level.level_id
      })

    other_node =
      stop_fixture(organization_id, version_id, %{
        parent_station: station.stop_id,
        level_id: level.level_id
      })

    pathway_fixture(organization_id, version_id, node.stop_id, other_node.stop_id)

    {:ok, _stop_level} =
      Gtfs.create_stop_level(%{
        organization_id: organization_id,
        gtfs_version_id: version_id,
        stop_id: station.id,
        level_id: level.id
      })

    %{station: station}
  end

  defp api_conn(conn, token, organization_id \\ nil) do
    conn =
      conn
      |> put_req_header("accept", "application/json")
      |> put_req_header("authorization", "Bearer #{token}")

    if organization_id, do: put_req_header(conn, "x-organization-id", organization_id), else: conn
  end

  defp entry_payload(target_type, attrs \\ %{}) do
    Map.merge(
      %{
        "id" => Ecto.UUID.generate(),
        "target_type" => target_type,
        "body" => "Mobile journal entry",
        "captured_at" => "2026-07-13T10:00:00Z"
      },
      attrs
    )
  end

  defp expected_entry(payload, author_id, extra) do
    Map.merge(
      %{
        "id" => payload["id"],
        "target_type" => payload["target_type"],
        "body" => payload["body"],
        "author_id" => author_id,
        "captured_at" => "2026-07-13T10:00:00.000000Z",
        "closed_at" => nil,
        "closed_by" => nil,
        "photos" => []
      },
      extra
    )
  end

  defp post_multipart(conn, url, metadata, bytes) do
    boundary = "station-journal-#{System.unique_integer([:positive])}"
    body = multipart_body(boundary, metadata, bytes)

    conn
    |> put_req_header("content-type", "multipart/form-data; boundary=#{boundary}")
    |> post(url, body)
  end

  defp multipart_body(boundary, metadata, bytes) do
    [
      "--",
      boundary,
      "\r\n",
      "content-disposition: form-data; name=\"metadata\"\r\n\r\n",
      Jason.encode!(metadata),
      "\r\n",
      "--",
      boundary,
      "\r\n",
      "content-disposition: form-data; name=\"file\"; filename=\"capture.jpg\"\r\n",
      "content-type: image/jpeg\r\n\r\n",
      bytes,
      "\r\n--",
      boundary,
      "--\r\n"
    ]
    |> IO.iodata_to_binary()
  end

  defp bundle_url(version_id, station_id),
    do: "/api/v1/versions/#{version_id}/stations/#{station_id}/bundle"

  defp sync_url(version_id, station_id),
    do: "/api/v1/versions/#{version_id}/stations/#{station_id}/sync"

  defp photo_url(version_id, station_id),
    do: "/api/v1/versions/#{version_id}/stations/#{station_id}/journal-photos"

  defp jpeg, do: <<0xFF, 0xD8, "journal", 0xFF, 0xD9>>

  defp journal_ids(bundle) do
    (bundle["journal_entries"] ++
       Enum.flat_map(bundle["stops"], & &1["journal_entries"]) ++
       Enum.flat_map(bundle["pathways"], & &1["journal_entries"]) ++
       Enum.flat_map(bundle["levels"], & &1["journal_entries"]))
    |> Enum.map(& &1["id"])
  end
end
