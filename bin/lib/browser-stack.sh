# shellcheck shell=bash
#
# Sourced by bin/test-browser and bin/ux-qa.
#
# The throwaway-Postgres startup, the free port, the asset build and the
# create/migrate/seed sequence that both browser entrypoints need. The function
# bodies are the text that used to live inline in bin/test-browser; only the
# wrapping moved.

# start_database [--keep]
#
# Exports GTFS_PLANNER_TEST_DATABASE_URL for a throwaway pg_tmp server, or keeps
# the one CI already provides. Must be called from the repository root.
start_database() {
  local keep=
  if [ "${1:-}" = "--keep" ]; then
    keep=1
  fi

  if [ -n "${CI:-}" ] && [ -n "${GTFS_PLANNER_TEST_DATABASE_URL:-}" ]; then
    echo "Postgres (from CI): ${GTFS_PLANNER_TEST_DATABASE_URL}" >&2
  else
    if ! command -v pg_tmp >/dev/null; then
      echo "pg_tmp not found. Install it with: brew install ephemeralpg" >&2
      exit 1
    fi

    # pg_tmp runs initdb and pg_ctl from PATH. Put Homebrew's PostgreSQL first so
    # another server's binaries on PATH are not the ones that start.
    for dir in /opt/homebrew/opt/postgresql@18/bin /usr/local/opt/postgresql@18/bin; do
      if [ -x "$dir/initdb" ]; then
        PATH="$dir:$PATH"
        break
      fi
    done

    # pg_tmp deletes the server once no client has been connected at a check made
    # every <timeout> seconds. Every gap without a connection below (mix startup,
    # asset build, the pause before Phoenix boots) ends well inside the first
    # ten minutes, so the first check finds Phoenix connected. After the run the
    # server disappears at the next check. --keep waits four hours instead.
    # Do not defer a check by holding a query open in the app's database: the
    # CREATE INDEX CONCURRENTLY migrations wait for it and time out.
    timeout=600
    if [ -n "$keep" ]; then
      timeout=14400
    fi

    # -t listens on TCP with a free port; loopback only, since pg_tmp uses trust
    # authentication and would otherwise listen on every interface.
    GTFS_PLANNER_TEST_DATABASE_URL=$(pg_tmp -t -w "$timeout" -o "-c listen_addresses=127.0.0.1")
    export GTFS_PLANNER_TEST_DATABASE_URL

    if [ -n "$keep" ]; then
      echo "Postgres (pg_tmp, kept until idle at a ${timeout}s check): ${GTFS_PLANNER_TEST_DATABASE_URL}" >&2
      echo "Connect with: psql '${GTFS_PLANNER_TEST_DATABASE_URL}'" >&2
    else
      echo "Postgres (pg_tmp): ${GTFS_PLANNER_TEST_DATABASE_URL}" >&2
    fi
  fi
}

# free_port
#
# Prints a free loopback TCP port for the Phoenix server.
free_port() {
  local port
  port=$(node -e 'const s = require("net").createServer().listen(0, "127.0.0.1", () => { console.log(s.address().port); s.close(); })')
  echo "$port"
}

# build_assets
build_assets() {
  mix assets.deploy
}

# prepare_database <seed script>
#
# Create, migrate, then run the given seed script (as in
# `mix run test/support/browser_seed.exs`).
prepare_database() {
  mix ecto.create
  mix ecto.migrate
  mix run "$1"
}
