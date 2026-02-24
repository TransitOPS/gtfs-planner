defmodule Mix.Tasks.Gtfs.Otp.Install do
  @moduledoc """
  Download local OTP artifacts used for export graph builds.

  ## Usage

      mix gtfs.otp.install
      mix gtfs.otp.install --dry-run
      mix gtfs.otp.install --force
      mix gtfs.otp.install --jar-url <url> --osm-url <url>

  ## Options

  - `--jar-url` overrides the OTP jar download URL
  - `--osm-url` overrides the OSM extract download URL
  - `--force` re-downloads files even if they already exist
  - `--skip-check` skips running `mix gtfs.otp.check --create-dir` after download
  - `--dry-run` prints planned actions without downloading
  """

  use Mix.Task

  alias GtfsPlanner.Otp.Prerequisites

  @shortdoc "Install OTP jar and OSM artifacts for local graph builds"

  @default_otp_jar_url "https://github.com/opentripplanner/OpenTripPlanner/releases/download/v2.8.1/otp-shaded-2.8.1.jar"
  @default_osm_url "https://download.bbbike.org/osm/bbbike/Philadelphia/Philadelphia.osm.pbf"

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, rest, invalid} =
      OptionParser.parse(args,
        strict: [
          jar_url: :string,
          osm_url: :string,
          force: :boolean,
          skip_check: :boolean,
          dry_run: :boolean
        ],
        aliases: [f: :force]
      )

    if rest != [] or invalid != [] do
      invalid_args = (rest ++ Enum.map(invalid, fn {k, _} -> "--#{k}" end)) |> Enum.join(" ")
      Mix.shell().error("Invalid arguments: #{invalid_args}")
      Mix.shell().info(@moduledoc)
      System.halt(1)
    end

    jar_url = opts[:jar_url] || @default_otp_jar_url
    osm_url = opts[:osm_url] || @default_osm_url
    force? = opts[:force] || false
    skip_check? = opts[:skip_check] || false
    dry_run? = opts[:dry_run] || false

    jar_path = fetch_env_path!(:otp_jar_path, "OTP_JAR_PATH")
    osm_path = fetch_env_path!(:otp_osm_path, "OTP_OSM_PATH")

    print_plan(jar_url, osm_url, jar_path, osm_path, force?, dry_run?)

    if dry_run? do
      :ok
    else
      ensure_parent_dir!(jar_path)
      ensure_parent_dir!(osm_path)

      download!(:otp_jar, jar_url, jar_path, force?)
      maybe_verify_jar_checksum!(jar_path)
      download!(:otp_osm, osm_url, osm_path, force?)

      unless skip_check? do
        report = Prerequisites.check(create_dir: true)

        Enum.each(report.checks, fn check ->
          prefix = if check.ok?, do: "[OK]", else: "[ERROR]"
          Mix.shell().info("#{prefix} #{check.name}: #{check.message}")
        end)

        Mix.shell().info(
          "Summary: #{length(report.checks) - report.errors} passed, #{report.errors} failed"
        )

        if report.errors > 0 do
          System.halt(1)
        end
      end
    end
  end

  defp fetch_env_path!(key, var_name) do
    case Application.get_env(:gtfs_planner, key) do
      path when is_binary(path) and path != "" ->
        if Path.type(path) == :absolute do
          path
        else
          Mix.raise("#{var_name} must be an absolute path (got: #{path})")
        end

      _ ->
        Mix.raise("#{var_name} is not configured")
    end
  end

  defp print_plan(jar_url, osm_url, jar_path, osm_path, force?, dry_run?) do
    mode = if dry_run?, do: "dry-run", else: "install"

    Mix.shell().info("Mode: #{mode}")
    Mix.shell().info("Force: #{force?}")
    Mix.shell().info("OTP jar URL: #{jar_url}")
    Mix.shell().info("OTP jar path: #{jar_path}")
    Mix.shell().info("OSM URL: #{osm_url}")
    Mix.shell().info("OSM path: #{osm_path}")
  end

  defp ensure_parent_dir!(path) do
    path
    |> Path.dirname()
    |> File.mkdir_p!()
  end

  defp download!(label, url, path, force?) do
    if File.exists?(path) and not force? do
      Mix.shell().info("Skipping #{label}: file already exists at #{path}")
    else
      Mix.shell().info("Downloading #{label} from #{url}")
      tmp_path = "#{path}.part"

      File.rm(tmp_path)

      case Req.get(url: url, into: File.stream!(tmp_path, [:write, :binary])) do
        {:ok, %Req.Response{status: status}} when status in 200..299 ->
          File.rename!(tmp_path, path)

          Mix.shell().info("Saved #{label} to #{path} (#{human_size(File.stat!(path).size)})")

        {:ok, %Req.Response{status: status, body: body}} ->
          File.rm(tmp_path)
          Mix.raise("Download failed for #{label} with HTTP #{status}: #{preview(body)}")

        {:error, reason} ->
          File.rm(tmp_path)
          Mix.raise("Download failed for #{label}: #{Exception.message(reason)}")
      end
    end
  end

  defp maybe_verify_jar_checksum!(jar_path) do
    case Application.get_env(:gtfs_planner, :otp_jar_sha256) do
      checksum when is_binary(checksum) and checksum != "" ->
        actual =
          jar_path
          |> File.stream!([], 2_097_152)
          |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
          |> :crypto.hash_final()
          |> Base.encode16(case: :lower)

        expected = checksum |> String.trim() |> String.downcase()

        if actual == expected do
          Mix.shell().info("Verified OTP jar checksum (sha256)")
        else
          Mix.raise("OTP jar checksum mismatch. expected=#{expected} actual=#{actual}")
        end

      _ ->
        :ok
    end
  end

  defp preview(body) when is_binary(body), do: body |> String.trim() |> String.slice(0, 120)
  defp preview(_body), do: "unexpected response body"

  defp human_size(size) when size < 1024, do: "#{size} B"

  defp human_size(size) when size < 1024 * 1024 do
    kb = Float.round(size / 1024, 1)
    "#{kb} KB"
  end

  defp human_size(size) when size < 1024 * 1024 * 1024 do
    mb = Float.round(size / (1024 * 1024), 1)
    "#{mb} MB"
  end

  defp human_size(size) do
    gb = Float.round(size / (1024 * 1024 * 1024), 2)
    "#{gb} GB"
  end
end
