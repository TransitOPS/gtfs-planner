# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

# The flex area editor uploads GeoJSON, and `.geojson` is not a suffix MIME
# knows; registering the RFC 7946 media type is what `allow_upload`'s
# `accept: ~w(.geojson .json)` needs on both sides (the file input's `accept`
# attribute and the server's entry validation). The Map line tab's path file
# upload adds KML, KMZ and GPX, which MIME does not know either: without these
# the accept list the upload is configured with cannot be built at all.
config :mime, :types, %{
  "application/geo+json" => ["geojson"],
  "application/vnd.google-earth.kml+xml" => ["kml"],
  "application/vnd.google-earth.kmz" => ["kmz"],
  "application/gpx+xml" => ["gpx"]
}

config :gtfs_planner,
  ecto_repos: [GtfsPlanner.Repo],
  generators: [timestamp_type: :utc_datetime],
  validator_module: GtfsPlanner.Gtfs.Validator,
  geocoding_service: GtfsPlanner.Geocoding.Geoapify,
  street_routing_service: GtfsPlanner.StreetRouting.Geoapify,
  boundaries_service: GtfsPlanner.Boundaries.Tigerweb,
  # Narrow external-boundary adapter used to read consumed upload files during a
  # full-feed import. Production reads with Elixir's `File`; tests can swap this
  # for a deterministic read-error stub. The adapter must expose `read/1`.
  import_file_reader: File,
  # Duration (in seconds) a preparation/execution/cleanup lease remains valid
  # before `reconcile_expired/1` may close it as interrupted/cleanup_failed.
  import_lease_seconds: 300,
  # Worker module that performs an already-claimed import. `Publication` closes
  # the run through `ImportRuns`.
  import_worker_module: GtfsPlanner.Gtfs.Import.Publication,
  # Worker module that performs an already-claimed cleanup. `Recovery` closes the
  # run through `ImportRuns` (created in step 7).
  import_cleanup_worker_module: GtfsPlanner.Gtfs.Import.Recovery,
  # Heartbeat interval (in milliseconds) at which the import runner renews its
  # execution/cleanup lease.
  import_runner_heartbeat_ms: 60_000,
  # Module the export worker runs before it builds a ZIP. Its `run/3` returns
  # `:ok` or `{:error, issues}`; each issue is stored as a run warning.
  otp_preflight_module: GtfsPlanner.Gtfs.Export.Preflight

# Every database session runs in UTC. Ecto's :utc_datetime columns are
# `timestamp without time zone`, so a value from CURRENT_TIMESTAMP, now() or a
# column default is stored in the session time zone; without this, a database
# that runs in another zone stores local time that the app reads back as UTC.
#
# The parameter is sent in the connection startup packet. A pooler that rejects
# unknown startup parameters (PgBouncer in transaction mode, a managed pooled
# endpoint) refuses the connection. If production does, remove this line and
# either run `ALTER ROLE <app role> SET timezone = 'UTC'` once on the database
# or use `after_connect: {Postgrex, :query!, ["SET TIME ZONE 'UTC'", []]}`.
config :gtfs_planner, GtfsPlanner.Repo, parameters: [timezone: "UTC"]

# Configure the endpoint
config :gtfs_planner, GtfsPlannerWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: GtfsPlannerWeb.ErrorHTML, json: GtfsPlannerWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: GtfsPlanner.PubSub,
  live_view: [signing_salt: "mj9kAsLh"],
  secret_key_base: "lP7H3l9d5mK2qR8wT4vZ6yX1nC0jF4sG8hB2kM5qR9wT3vY7zA1cD4eF8gH2jK5lP"

# OpenRouter chat-completions client for the agent helper. The base URL is
# code configuration; the selected model and the API key are runtime
# configuration (`config/runtime.exs`), and the model has no default.
config :gtfs_planner, GtfsPlanner.Agents.Model, base_url: "https://openrouter.ai/api/v1"

# Configure the mailer
#
# By default it uses the "Local" adapter which stores the emails
# locally. You can see the emails in your browser, at "/dev/mailbox".
#
# For production it's recommended to configure a different adapter
# at the `config/runtime.exs`.
config :gtfs_planner, GtfsPlanner.Mailer, adapter: Swoosh.Adapters.Local

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  gtfs_planner: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --external:images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.1.12",
  gtfs_planner: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__)
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [
    :request_id,
    :event,
    :organization_id,
    :version_id,
    :gtfs_version_id,
    :station_stop_id,
    :stop_id,
    :dragging_stop_id,
    :mode,
    :phase,
    :transition,
    :failure_class,
    :reason,
    :state,
    :photo_id,
    :journal_entry_id,
    :issue_codes,
    :details,
    :x,
    :y,
    # Agent turn outcomes: one terminal line per finished helper turn.
    :pack,
    :model,
    :outcome,
    :tools,
    :duration_ms,
    :cost,
    :cost_complete
  ]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Filter password- and token-bearing keys from structured parameter logging.
# This covers substring matches (current_password, password_confirmation) but
# does not redact tokens embedded in URL paths.
config :phoenix, :filter_parameters, ["password", "token"]

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
