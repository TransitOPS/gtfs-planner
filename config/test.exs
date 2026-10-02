import Config

# Configure your database
#
# Tests connect as `gtfs_planner_test`, a role that cannot connect to
# `gtfs_planner_dev`. `bin/setup-test-db-role` creates it and revokes PUBLIC connect
# on the dev database. That role owns only the databases it creates, so they use the
# `gtfs_planner_exunit` prefix; the older `gtfs_planner_test*` databases belong to
# `postgres`.
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
database = "gtfs_planner_exunit#{System.get_env("MIX_TEST_PARTITION")}"

# Only `bin/test-browser` and the browser CI job set this variable, to point the Repo
# at a throwaway Postgres; the partition-based default above stays in effect for
# ordinary `mix test` runs. A plain DATABASE_URL is ignored in test on purpose. The
# `gtfs_planner_exunit` prefix and the name `test` are also what
# `GtfsPlanner.DatabaseGuard` allows the drop task to touch.
database_url = System.get_env("GTFS_PLANNER_TEST_DATABASE_URL")

url_database =
  if database_url do
    uri = URI.parse(database_url)
    name = String.trim_leading(uri.path || "", "/")

    allowed? =
      uri.host in ["127.0.0.1", "localhost", "::1"] and is_nil(uri.query) and
        (name == "test" or String.starts_with?(name, "gtfs_planner_exunit"))

    if not allowed? do
      raise """
      GTFS_PLANNER_TEST_DATABASE_URL is refused (host #{inspect(uri.host)}, database \
      #{inspect(name)}). In test it must have a loopback host (127.0.0.1, localhost \
      or ::1), no query string, and a database named `test` (pg_tmp's) or starting \
      with `gtfs_planner_exunit`.
      """
    end

    name
  end

if (url_database || database) == "gtfs_planner_dev" do
  raise "The test environment must never use the gtfs_planner_dev database."
end

config :gtfs_planner, GtfsPlanner.Repo,
  username: "gtfs_planner_test",
  password: "gtfs_planner_test",
  hostname: "localhost",
  database: database,
  pool: Ecto.Adapters.SQL.Sandbox,
  # Two connections per scheduler is two on a single-scheduler host. The interleaving
  # cases in `test/gtfs_planner/gtfs/blocking/concurrency_test.exs` hold one connection
  # per holder, one per concurrent command and one for the shared sandbox owner, so a
  # four-connection case has no margin at `2 * 2` and does not fit below it. Ecto offers
  # no per-module pool size, and this 10 matches what `config/dev.exs` and
  # `config/runtime.exs` already use.
  pool_size: max(System.schedulers_online() * 2, 10),
  # A LiveView render and an async task share the test's sandbox connection, so
  # a busy machine can queue a checkout past DBConnection's 50 ms target and
  # have the request dropped. Wait like the dev and runtime pools do instead of
  # failing a test for the host's load.
  queue_target: 5_000,
  queue_interval: 30_000

if database_url do
  config :gtfs_planner, GtfsPlanner.Repo, url: database_url
end

# Use a deterministic final-validator adapter for browser journeys while ordinary
# ExUnit cases retain process-owned Mox expectations. The QA launcher starts its
# server with `BROWSER_E2E` so the stubs for external services stay in place, and
# sets `UX_QA_REAL_VALIDATOR` so validation runs the tracked jar instead of a stub;
# with it unset every existing run is unchanged.
validator_module =
  cond do
    System.get_env("BROWSER_E2E") == "true" and System.get_env("UX_QA_REAL_VALIDATOR") == "true" ->
      GtfsPlanner.Gtfs.Validator

    System.get_env("BROWSER_E2E") == "true" ->
      GtfsPlanner.Gtfs.BrowserValidator

    true ->
      GtfsPlanner.Gtfs.ValidatorMock
  end

config :gtfs_planner, :validator_module, validator_module
config :gtfs_planner, :api_cors_allow_localhost, true

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :gtfs_planner, GtfsPlannerWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  check_origin: false,
  secret_key_base: "Vlqg9A56iIf2P4HgwZAFhhA0raEXyKKmoZ5xjBmuiZUjDE1FI9/OpjJ/HRgFfTIE",
  server: false

# Browser journeys search an address in a real browser, where no process-owned
# Mox expectation exists. Ordinary ExUnit cases keep the mock; production keeps
# GtfsPlanner.Geocoding.Geoapify.
geocoding_module =
  if System.get_env("BROWSER_E2E") == "true" do
    GtfsPlanner.BrowserGeocoding
  else
    GtfsPlanner.GeocodingMock
  end

config :gtfs_planner, :geocoding_service, geocoding_module

# Alignment street generation routes through the server-side Geoapify adapter in
# ordinary ExUnit runs. Browser journeys drive generation in a real browser, where
# no Req.Test stub exists, so they use the deterministic fake instead.
street_routing_module =
  if System.get_env("BROWSER_E2E") == "true" do
    GtfsPlanner.BrowserStreetRouting
  else
    GtfsPlanner.StreetRouting.Geoapify
  end

config :gtfs_planner, :street_routing_service, street_routing_module

# Census boundary picks go through the TIGERweb adapter in ordinary ExUnit runs,
# where responses come from recorded fixtures through a `Req.Test` plug. Browser
# journeys drive the area editor in a real browser, where no such plug exists, so
# they use the deterministic fixture-backed fake instead.
boundaries_module =
  if System.get_env("BROWSER_E2E") == "true" do
    GtfsPlanner.BrowserBoundaries
  else
    GtfsPlanner.Boundaries.Tigerweb
  end

config :gtfs_planner, :boundaries_service, boundaries_module

# Route Req HTTP calls in the Census TIGERweb adapter through Req.Test so tests
# can stub upstream boundary and water responses.
config :gtfs_planner, :boundaries_req_plug, {Req.Test, GtfsPlanner.Boundaries.Tigerweb}

# Route Req HTTP calls in the street routing adapter through Req.Test so
# tests can stub upstream routing responses.
config :gtfs_planner, :street_routing_req_plug, {Req.Test, GtfsPlanner.StreetRouting.Geoapify}

# Route Geoapify autocomplete requests through Req.Test in ordinary ExUnit runs.
config :gtfs_planner,
       :geocoding_req_options, plug: {Req.Test, GtfsPlanner.Geocoding.Geoapify}, retry_delay: 0

# Route Req HTTP calls in the map tiles controller through Req.Test so
# tests can stub upstream tile responses.
config :gtfs_planner, :map_tiles_req_plug, {Req.Test, GtfsPlannerWeb.MapTilesController}

# Stub Overpass upstream for the buildings controller in tests.
config :gtfs_planner,
       :map_buildings_req_plug,
       {Req.Test, GtfsPlannerWeb.MapBuildingsController}

# Ordinary tests use dummy OpenRouter configuration and always route through a
# Req.Test plug, so no test can reach the provider. Only the default-excluded
# `:agent_scenarios` suite replaces these values, and it restores them.
config :gtfs_planner, GtfsPlanner.Agents.Model, model: "test/model-a"

config :gtfs_planner, GtfsPlanner.Agents.UsageBudget,
  organization_daily_attempts: 1000,
  actor_daily_attempts: 1000

config :gtfs_planner, :openrouter_api_key, "test-openrouter-key"

# The helper's browser journey drives the helper in a real browser, where no
# Req.Test stub exists, so a deterministic scripted stand-in answers OpenRouter.
# Ordinary ExUnit runs keep the Req.Test plug.
agents_req_options =
  if System.get_env("BROWSER_E2E") == "true" do
    [plug: GtfsPlanner.Agents.BrowserOpenRouter]
  else
    [plug: {Req.Test, GtfsPlanner.Agents.Model}, retry_delay: 0]
  end

config :gtfs_planner, :agents_req_options, agents_req_options

# In test we don't send emails
config :gtfs_planner, GtfsPlanner.Mailer, adapter: Swoosh.Adapters.Test

# The SQL sandbox already holds an open transaction, so it cannot change the
# enclosing transaction's isolation level. The export-race test selects the
# production Repo snapshot boundary directly.
config :gtfs_planner,
       :gtfs_export_snapshot,
       GtfsPlanner.Gtfs.Export.Snapshot.Sandbox

config :gtfs_planner,
       :gtfs_service_query_snapshot,
       GtfsPlanner.Gtfs.ServiceQueries.Snapshot.Sandbox

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

# Public feed publishing stays disabled in ordinary runs: `config/runtime.exs` never
# reads GTFS_PUBLISH_* in test, so ambient production secrets cannot activate it. A
# case that installs a loopback storage boundary opts in explicitly below; the fixture
# is a raw settings map because this file is compiled before
# `GtfsPlanner.FeedPublishing.Config` exists, and `current/0` normalizes it on read.
if System.get_env("GTFS_PUBLISH_TEST_LOOPBACK") == "true" do
  config :gtfs_planner, :feed_publishing_settings, %{
    "GTFS_PUBLISH_BUCKET" => "gtfs-planner-loopback",
    "GTFS_PUBLISH_ENDPOINT" => "https://storage.loopback.invalid",
    "GTFS_PUBLISH_REGION" => "us-east-1",
    "GTFS_PUBLISH_ACCESS_KEY_ID" => "loopback-access-key",
    "GTFS_PUBLISH_SECRET_ACCESS_KEY" => "loopback-secret-access-key",
    "GTFS_PUBLISH_PUBLIC_BASE_URL" => "https://feeds.loopback.invalid"
  }
end

# Feed-publishing storage substitutes only the Req final HTTP transport in test,
# so no test can reach an object store while the concrete Req/SigV4 request
# construction stays real. `GtfsPlanner.FeedPublishing.HTTPBoundary` is an
# in-memory object store keyed by the calling process, so a test that seeds an
# object or asserts on the signed request owns its own state.
config :gtfs_planner,
  :feed_publishing_http_options,
  finch_request: &GtfsPlanner.FeedPublishing.HTTPBoundary.request/4

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
