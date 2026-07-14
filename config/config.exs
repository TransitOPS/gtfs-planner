# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :gtfs_planner,
  ecto_repos: [GtfsPlanner.Repo],
  generators: [timestamp_type: :utc_datetime],
  validator_module: GtfsPlanner.Gtfs.Validator,
  geocoding_service: GtfsPlanner.Geocoding.Geoapify

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
    :gtfs_version_id,
    :station_stop_id,
    :stop_id,
    :dragging_stop_id,
    :mode,
    :phase,
    :reason,
    :state,
    :photo_id,
    :journal_entry_id,
    :issue_codes,
    :details,
    :x,
    :y
  ]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
