import Config

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :gtfs_planner, GtfsPlanner.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "gtfs_planner_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# Use a deterministic final-validator adapter for browser journeys while ordinary
# ExUnit cases retain process-owned Mox expectations.
validator_module =
  if System.get_env("BROWSER_E2E") == "true" do
    GtfsPlanner.Gtfs.BrowserValidator
  else
    GtfsPlanner.Gtfs.ValidatorMock
  end

config :gtfs_planner, :validator_module, validator_module

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :gtfs_planner, GtfsPlannerWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  check_origin: false,
  secret_key_base: "Vlqg9A56iIf2P4HgwZAFhhA0raEXyKKmoZ5xjBmuiZUjDE1FI9/OpjJ/HRgFfTIE",
  server: false

config :gtfs_planner, :geocoding_service, GtfsPlanner.GeocodingMock

# Route Req HTTP calls in the map tiles controller through Req.Test so
# tests can stub upstream tile responses.
config :gtfs_planner, :map_tiles_req_plug, {Req.Test, GtfsPlannerWeb.MapTilesController}

# Stub Overpass upstream for the buildings controller in tests.
config :gtfs_planner,
       :map_buildings_req_plug,
       {Req.Test, GtfsPlannerWeb.MapBuildingsController}

# In test we don't send emails
config :gtfs_planner, GtfsPlanner.Mailer, adapter: Swoosh.Adapters.Test

config :gtfs_planner,
       :reviewed_apply_transaction,
       GtfsPlanner.Gtfs.ReviewedApplyTransaction.Sandbox

# Disable swoosh api client as it is only required for production adapters
config :swoosh, :api_client, false

# Use isolated temp directory for uploads during tests
config :gtfs_planner, :uploads_path, Path.join(System.tmp_dir!(), "gtfs_planner_test_uploads")

# Durable task artifacts are private and intentionally separate from upload/static routing.
config :gtfs_planner,
  gtfs_task_artifacts_path: Path.join(System.tmp_dir!(), "gtfs_planner_test_task_artifacts"),
  gtfs_task_artifacts_max_run_bytes: 150 * 1024 * 1024,
  gtfs_task_artifacts_max_total_bytes: 1024 * 1024 * 1024,
  gtfs_task_artifacts_ttl_seconds: 24 * 60 * 60

# Maintenance is exercised explicitly so SQL sandbox tests retain process ownership.
config :gtfs_planner, :task_artifact_maintenance_enabled, false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true
