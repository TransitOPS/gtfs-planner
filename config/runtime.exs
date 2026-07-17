import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/gtfs_planner start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.

if config_env() in [:dev, :test] and File.exists?(".env") do
  DotenvParser.load_file(".env")
end

if System.get_env("PHX_SERVER") do
  config :gtfs_planner, GtfsPlannerWeb.Endpoint, server: true
end

config :gtfs_planner, GtfsPlannerWeb.Endpoint,
  http: [port: String.to_integer(System.get_env("PORT", "4000"))]

config :gtfs_planner,
       :gtfs_validator_path,
       System.get_env("GTFS_VALIDATOR_JAR") ||
         if(config_env() == :prod,
           do: "/opt/gtfs-validator/gtfs-validator-cli.jar",
           else: Path.expand("../priv/gtfs_validator/gtfs-validator-cli.jar", __DIR__)
         )

config :gtfs_planner,
       :java_path,
       System.get_env("JAVA_PATH") ||
         if(config_env() == :prod,
           do: "java",
           else: "/opt/homebrew/opt/openjdk@21/bin/java"
         )

config :gtfs_planner,
       :otp_jar_path,
       System.get_env("OTP_JAR_PATH") ||
         if(config_env() == :prod,
           do: "/opt/otp/otp.jar",
           else: Path.expand("../priv/otp/opentripplanner.jar", __DIR__)
         )

config :gtfs_planner,
       :otp_osm_path,
       System.get_env("OTP_OSM_PATH") ||
         if(config_env() == :prod,
           do: "/opt/otp/data/philadelphia.osm.pbf",
           else: Path.expand("../priv/otp/region.osm.pbf", __DIR__)
         )

config :gtfs_planner,
       :otp_runtime_path,
       System.get_env("OTP_RUNTIME_PATH") ||
         Path.join(System.tmp_dir!(), "gtfs_planner/otp_runtime")

config :gtfs_planner,
       :otp_artifacts_path,
       System.get_env("OTP_ARTIFACTS_PATH") ||
         Path.join(System.tmp_dir!(), "gtfs_planner_otp_artifacts")

config :gtfs_planner,
       :otp_graph_build_heap,
       System.get_env("OTP_GRAPH_BUILD_HEAP") || "4G"

config :gtfs_planner,
       :otp_graph_build_timeout_ms,
       System.get_env("OTP_GRAPH_BUILD_TIMEOUT_MS", "600000")
       |> String.to_integer()

config :gtfs_planner, :otp_server_host, System.get_env("OTP_SERVER_HOST") || "127.0.0.1"

config :gtfs_planner,
       :otp_server_port,
       System.get_env("OTP_SERVER_PORT", "8080")
       |> String.to_integer()

config :gtfs_planner, :otp_server_heap, System.get_env("OTP_SERVER_HEAP") || "4G"

config :gtfs_planner,
       :otp_server_ready_timeout_ms,
       System.get_env("OTP_SERVER_READY_TIMEOUT_MS", "30000")
       |> String.to_integer()

config :gtfs_planner,
       :otp_server_ready_poll_interval_ms,
       System.get_env("OTP_SERVER_READY_POLL_INTERVAL_MS", "250")
       |> String.to_integer()

config :gtfs_planner,
       :otp_server_shutdown_timeout_ms,
       System.get_env("OTP_SERVER_SHUTDOWN_TIMEOUT_MS", "5000")
       |> String.to_integer()

config :gtfs_planner,
       :otp_graphql_path,
       System.get_env("OTP_GRAPHQL_PATH") || "/otp/routers/default/index/graphql"

config :gtfs_planner, :otp_jar_sha256, System.get_env("OTP_JAR_SHA256")

config :gtfs_planner, :mail_domain, System.get_env("MAIL_DOMAIN") || "gtfsplanner.com"

if config_env() != :test do
  config :gtfs_planner,
         :uploads_path,
         System.get_env("UPLOADS_PATH") ||
           Path.join(:code.priv_dir(:gtfs_planner), "static/uploads")
end

config :gtfs_planner,
       :import_max_zip_uncompressed_bytes,
       (case Integer.parse(System.get_env("IMPORT_MAX_ZIP_UNCOMPRESSED_BYTES") || "") do
          {value, ""} when value > 0 -> value
          _ -> 500 * 1024 * 1024
        end)

case Integer.parse(System.get_env("IMPORT_MAX_ZIP_ENTRY_UNCOMPRESSED_BYTES") || "") do
  {value, ""} when value > 0 ->
    config :gtfs_planner, :import_max_zip_entry_uncompressed_bytes, value

  _ ->
    :ok
end

config :gtfs_planner,
       :geoapify_api_key,
       System.get_env("GEOAPIFY_API_KEY") ||
         if(config_env() == :prod,
           do: raise("environment variable GEOAPIFY_API_KEY is missing"),
           else: nil
         )

if config_env() == :prod do
  database_url =
    System.get_env("DATABASE_URL") ||
      raise """
      environment variable DATABASE_URL is missing.
      For example: ecto://USER:PASS@HOST/DATABASE
      """

  maybe_ipv6 = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []

  config :gtfs_planner, GtfsPlanner.Repo,
    # ssl: true,
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
    # For machines with several cores, consider starting multiple pools of `pool_size`
    # pool_count: 4,
    socket_options: maybe_ipv6,
    # Increased timeouts for large GTFS imports (30+ files)
    timeout: 300_000,
    queue_target: 5_000,
    queue_interval: 30_000

  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST") || "example.com"

  # Configure origin checking for WebSocket connections
  # For local Docker development, set PHX_CHECK_ORIGIN=false
  # For production with specific origins, set PHX_CHECK_ORIGIN="//example.com,//www.example.com"
  check_origin =
    case System.get_env("PHX_CHECK_ORIGIN") do
      "false" -> false
      nil -> true
      origins -> String.split(origins, ",") |> Enum.map(&String.trim/1)
    end

  config :gtfs_planner, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :gtfs_planner, GtfsPlannerWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    check_origin: check_origin,
    http: [
      # Enable IPv6 and bind on all interfaces.
      # Set it to  {0, 0, 0, 0, 0, 0, 0, 1} for local network only access.
      # See the documentation on https://hexdocs.pm/bandit/Bandit.html#t:options/0
      # for details about using IPv6 vs IPv4 and loopback vs public addresses.
      ip: {0, 0, 0, 0, 0, 0, 0, 0}
    ],
    secret_key_base: secret_key_base

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :gtfs_planner, GtfsPlannerWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://hexdocs.pm/plug/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :gtfs_planner, GtfsPlannerWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.

  ses_region = System.get_env("AWS_SES_REGION") || System.get_env("AWS_REGION")

  if ses_region do
    config :ex_aws,
      http_client: ExAws.Request.Req,
      access_key_id: [:instance_role],
      secret_access_key: [:instance_role],
      region: ses_region

    mailer_config = [
      adapter: Swoosh.Adapters.ExAwsAmazonSES,
      region: ses_region
    ]

    mailer_config =
      case System.get_env("AWS_SES_CONFIGURATION_SET") do
        nil -> mailer_config
        set -> Keyword.put(mailer_config, :configuration_set_name, set)
      end

    config :gtfs_planner, GtfsPlanner.Mailer, mailer_config
  else
    config :gtfs_planner, GtfsPlanner.Mailer, adapter: Swoosh.Adapters.Logger
  end
end
