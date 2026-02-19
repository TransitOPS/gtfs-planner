defmodule GtfsPlanner.Otp.RuntimeTest do
  use ExUnit.Case, async: true

  alias GtfsPlanner.Otp.Runtime

  test "prepare_runtime/3 composes GTFS and graph materializers" do
    status_callback = fn payload -> send(self(), {:status, payload}) end

    gtfs_fun = fn "org-1", "ver-1", opts ->
      opts[:status_callback].(%{phase: :done, reused: false})

      {:ok, "/tmp/otp/gtfs.zip",
       %{reused: false, content_hash: "gtfs-hash", file_size_bytes: 100, manifest_json: %{}}}
    end

    graph_fun = fn "org-1", "ver-1", opts ->
      opts[:status_callback].(%{phase: :done, reused: true})

      {:ok, "/tmp/otp/Graph.obj",
       %{reused: true, manifest_path: "/tmp/otp/manifest.json", manifest_json: %{}}}
    end

    assert {:ok, result} =
             Runtime.prepare_runtime("org-1", "ver-1",
               status_callback: status_callback,
               gtfs_materializer_fun: gtfs_fun,
               graph_materializer_fun: graph_fun
             )

    assert result.gtfs_zip_path == "/tmp/otp/gtfs.zip"
    assert result.graph_path == "/tmp/otp/Graph.obj"
    assert result.meta.gtfs.content_hash == "gtfs-hash"
    assert result.meta.graph.reused

    assert_receive {:status, %{scope: :gtfs, phase: :done, reused: false}}
    assert_receive {:status, %{scope: :graph, phase: :done, reused: true}}
  end

  test "prepare_runtime/3 forwards preflight_mode to GTFS materializer when missing from gtfs_opts" do
    gtfs_fun = fn "org-1", "ver-1", opts ->
      send(self(), {:gtfs_opts, opts})
      {:ok, "/tmp/otp/gtfs.zip", %{}}
    end

    graph_fun = fn "org-1", "ver-1", _opts ->
      {:ok, "/tmp/otp/Graph.obj", %{}}
    end

    assert {:ok, _result} =
             Runtime.prepare_runtime("org-1", "ver-1",
               preflight_mode: :lenient,
               gtfs_materializer_fun: gtfs_fun,
               graph_materializer_fun: graph_fun
             )

    assert_receive {:gtfs_opts, gtfs_opts}
    assert gtfs_opts[:preflight_mode] == :lenient
  end

  test "prepare_runtime/3 returns GTFS errors without invoking graph materializer" do
    gtfs_issues = [%{code: :preflight_failed}]

    gtfs_fun = fn "org-1", "ver-1", _opts ->
      {:error, gtfs_issues}
    end

    graph_fun = fn _org, _ver, _opts ->
      send(self(), :graph_called)
      {:ok, "/tmp/otp/Graph.obj", %{}}
    end

    assert {:error, ^gtfs_issues} =
             Runtime.prepare_runtime("org-1", "ver-1",
               gtfs_materializer_fun: gtfs_fun,
               graph_materializer_fun: graph_fun
             )

    refute_received :graph_called
  end
end
