defmodule GtfsPlanner.Otp.Prerequisites do
  @moduledoc """
  Validates local OTP graph build prerequisites used by manual export testing.
  """

  @min_java_major 21
  @min_heap_bytes 4 * 1024 * 1024 * 1024

  @type check_result :: %{name: atom(), ok?: boolean(), message: String.t()}
  @type result :: %{checks: [check_result()], errors: non_neg_integer()}

  @spec check(keyword()) :: result()
  def check(opts \\ []) do
    create_dir? = Keyword.get(opts, :create_dir, false)

    checks = [
      check_java(),
      check_otp_dir(create_dir?),
      check_jar(),
      check_osm(),
      check_heap()
    ]

    %{checks: checks, errors: Enum.count(checks, &(not &1.ok?))}
  end

  defp check_java do
    java_path = Application.get_env(:gtfs_planner, :java_path)

    cond do
      not is_binary(java_path) or String.trim(java_path) == "" ->
        fail(:java, "JAVA_PATH is missing")

      true ->
        run_java_version(java_path)
    end
  end

  defp run_java_version(java_path) do
    trimmed_path = String.trim(java_path)

    not_found? =
      if Path.type(trimmed_path) == :absolute do
        not File.exists?(trimmed_path)
      else
        is_nil(System.find_executable(trimmed_path))
      end

    if not_found? do
      fail(:java, "Java binary not found at #{trimmed_path}")
    else
      case System.cmd(trimmed_path, ["-version"], stderr_to_stdout: true) do
        {output, 0} ->
          case parse_java_major(output) do
            {:ok, major} when major >= @min_java_major ->
              pass(:java, "Java #{major} available at #{trimmed_path}")

            {:ok, major} ->
              fail(:java, "Java #{major} found, but Java #{@min_java_major}+ is required")

            :error ->
              fail(:java, "Could not parse Java version from: #{first_line(output)}")
          end

        {output, _code} ->
          fail(:java, "Failed to run '#{trimmed_path} -version': #{first_line(output)}")
      end
    end
  rescue
    error -> fail(:java, "Failed to run Java command: #{Exception.message(error)}")
  end

  defp parse_java_major(output) do
    regex = ~r/version\s+"(?<version>[^"]+)"/

    case Regex.named_captures(regex, output) do
      %{"version" => version} ->
        version
        |> String.split([".", "_", "-"])
        |> parse_java_major_parts()

      _ ->
        :error
    end
  end

  defp parse_java_major_parts(["1", minor | _rest]) do
    case Integer.parse(minor) do
      {major, _} -> {:ok, major}
      :error -> :error
    end
  end

  defp parse_java_major_parts([major | _rest]) do
    case Integer.parse(major) do
      {int, _} -> {:ok, int}
      :error -> :error
    end
  end

  defp parse_java_major_parts(_parts), do: :error

  defp check_otp_dir(create_dir?) do
    otp_dir = otp_dir_path()

    case File.stat(otp_dir) do
      {:ok, %File.Stat{type: :directory}} ->
        pass(:otp_dir, "OTP directory exists at #{otp_dir}")

      _ ->
        if create_dir? do
          case File.mkdir_p(otp_dir) do
            :ok ->
              pass(:otp_dir, "Created OTP directory at #{otp_dir}")

            {:error, reason} ->
              fail(:otp_dir, "Could not create OTP directory: #{inspect(reason)}")
          end
        else
          fail(:otp_dir, "OTP directory missing at #{otp_dir} (run with --create-dir)")
        end
    end
  end

  defp check_jar do
    check_file_path(:otp_jar, Application.get_env(:gtfs_planner, :otp_jar_path), ".jar")
  end

  defp check_osm do
    check_file_path(:otp_osm, Application.get_env(:gtfs_planner, :otp_osm_path), ".pbf")
  end

  defp check_file_path(name, path, extension) do
    cond do
      not is_binary(path) or String.trim(path) == "" ->
        fail(name, "Path is missing")

      Path.type(path) != :absolute ->
        fail(name, "Path must be absolute: #{path}")

      not String.ends_with?(path, extension) ->
        fail(name, "Path must end with #{extension}: #{path}")

      not File.exists?(path) ->
        fail(name, "File not found: #{path}")

      not File.regular?(path) ->
        fail(name, "Path is not a regular file: #{path}")

      not readable_file?(path) ->
        fail(name, "File is not readable: #{path}")

      true ->
        pass(name, "File is present: #{path}")
    end
  end

  defp check_heap do
    heap = Application.get_env(:gtfs_planner, :otp_graph_build_heap, "4G")

    with {:ok, heap_bytes} <- parse_heap_bytes(heap),
         :ok <- ensure_heap_min(heap_bytes),
         :ok <- ensure_heap_fits_system_memory(heap_bytes) do
      pass(:heap, "OTP graph build heap is configured to #{heap}")
    else
      {:error, reason} -> fail(:heap, reason)
    end
  end

  defp parse_heap_bytes(heap) when is_binary(heap) do
    regex = ~r/^\s*(?<value>\d+)\s*(?<unit>[kKmMgG])\s*$/

    case Regex.named_captures(regex, heap) do
      %{"value" => value, "unit" => unit} ->
        {int, _} = Integer.parse(value)
        multiplier = heap_multiplier(unit)
        {:ok, int * multiplier}

      _ ->
        {:error, "OTP_GRAPH_BUILD_HEAP must look like 4G, 4096M, etc. (got: #{heap})"}
    end
  end

  defp parse_heap_bytes(_heap), do: {:error, "OTP_GRAPH_BUILD_HEAP is missing"}

  defp heap_multiplier(unit) when unit in ["k", "K"], do: 1024
  defp heap_multiplier(unit) when unit in ["m", "M"], do: 1024 * 1024
  defp heap_multiplier(unit) when unit in ["g", "G"], do: 1024 * 1024 * 1024

  defp ensure_heap_min(bytes) when bytes >= @min_heap_bytes, do: :ok

  defp ensure_heap_min(_bytes) do
    {:error, "OTP_GRAPH_BUILD_HEAP must be at least 4G for graph builds"}
  end

  defp ensure_heap_fits_system_memory(heap_bytes) do
    case system_memory_bytes() do
      {:ok, system_bytes} when heap_bytes > system_bytes ->
        {:error,
         "OTP_GRAPH_BUILD_HEAP exceeds detected system RAM (heap=#{heap_bytes}, ram=#{system_bytes})"}

      _ ->
        :ok
    end
  end

  defp system_memory_bytes do
    case :os.type() do
      {:unix, :darwin} ->
        case System.cmd("sysctl", ["-n", "hw.memsize"], stderr_to_stdout: true) do
          {output, 0} ->
            output
            |> String.trim()
            |> Integer.parse()
            |> case do
              {bytes, _} -> {:ok, bytes}
              :error -> :error
            end

          _ ->
            :error
        end

      {:unix, :linux} ->
        case File.read("/proc/meminfo") do
          {:ok, meminfo} ->
            case Regex.named_captures(~r/MemTotal:\s+(?<kb>\d+)\s+kB/, meminfo) do
              %{"kb" => kb} ->
                {int, _} = Integer.parse(kb)
                {:ok, int * 1024}

              _ ->
                :error
            end

          _ ->
            :error
        end

      _ ->
        :error
    end
  end

  defp otp_dir_path do
    Application.get_env(:gtfs_planner, :otp_jar_path)
    |> case do
      path when is_binary(path) -> Path.dirname(path)
      _ -> Path.expand("priv/otp")
    end
  end

  defp readable_file?(path) do
    case File.open(path, [:read]) do
      {:ok, file} ->
        File.close(file)
        true

      {:error, _reason} ->
        false
    end
  end

  defp first_line(output) do
    output
    |> String.split("\n")
    |> List.first()
    |> to_string()
    |> String.trim()
  end

  defp pass(name, message), do: %{name: name, ok?: true, message: message}
  defp fail(name, message), do: %{name: name, ok?: false, message: message}
end
