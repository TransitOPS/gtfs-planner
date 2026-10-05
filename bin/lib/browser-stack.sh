# shellcheck shell=bash
#
# Sourced by bin/test-browser and bin/ux-qa.
#
# The throwaway-Postgres startup, the free port, the asset build and the
# create/migrate/seed sequence that both browser entrypoints need. The function
# bodies are the text that used to live inline in bin/test-browser; only the
# wrapping moved.

# detach_spawn <log file> <command> [argument...]
#
# Runs the command in a session of its own and prints its pid. macOS has no
# `setsid`, so the toolchain's own runtime does it: a detached child leads its
# own process group, so the caller's shell going away does not take it with it.
# Output still goes to the log the caller named. The caller supplies its own
# command line, so this changes no existing caller's behaviour.
detach_spawn() {
  node -e '
const { spawn } = require("node:child_process");
const { openSync } = require("node:fs");

const [logPath, command, ...args] = process.argv.slice(1);
const log = openSync(logPath, "a");

const child = spawn(command, args, { detached: true, stdio: ["ignore", log, log] });

child.unref();
process.stdout.write(String(child.pid));
' "$1" "${@:2}"
}

# detach_capture <command> [argument...]
#
# The same detachment for a command whose answer this shell has to read: the
# command runs in a session of its own, its standard output is captured, and
# that output is printed unchanged. Its own output goes to the caller's
# terminal, exactly as running it directly would have sent it there.
detach_capture() {
  node -e '
const { spawnSync } = require("node:child_process");

const result = spawnSync(process.argv[1], process.argv.slice(2), {
  detached: true,
  stdio: ["ignore", "pipe", "inherit"],
  encoding: "utf8"
});

process.stdout.write(result.stdout || "");
process.exit(result.status === null ? 1 : result.status);
' "$@"
}

# use_homebrew_postgres
#
# pg_tmp runs initdb, pg_ctl and psql from PATH. Put Homebrew's PostgreSQL first
# so another server's binaries on PATH are not the ones that start or stop it.
use_homebrew_postgres() {
  local dir
  for dir in /opt/homebrew/opt/postgresql@18/bin /usr/local/opt/postgresql@18/bin; do
    if [ -x "$dir/initdb" ]; then
      PATH="$dir:$PATH"
      break
    fi
  done
}

# start_database [--keep] [--datadir <dir>]
#
# Exports GTFS_PLANNER_TEST_DATABASE_URL for a throwaway pg_tmp server, or keeps
# the one CI already provides. Must be called from the repository root.
#
# --datadir puts the server's data in <dir> (pg_tmp creates it; the data lives
# in <dir>/<postgres version>) so the caller can stop it with stop_database. A
# caller that names its own directory wants its own server, so the CI server is
# not reused for it.
# shellcheck disable=SC2120 # callers may pass no args; --keep/--datadir handled above
start_database() {
  local keep='' datadir=''
  while [ $# -gt 0 ]; do
    case "$1" in
      --keep)
        keep=1
        shift
        ;;
      --datadir)
        if [ $# -lt 2 ] || [ -z "$2" ]; then
          echo "start_database: --datadir needs a directory" >&2
          exit 1
        fi
        datadir=$2
        shift 2
        ;;
      *)
        echo "start_database: unknown argument: $1" >&2
        exit 1
        ;;
    esac
  done

  if [ -z "$datadir" ] && [ -n "${CI:-}" ] && [ -n "${GTFS_PLANNER_TEST_DATABASE_URL:-}" ]; then
    echo "Postgres (from CI): ${GTFS_PLANNER_TEST_DATABASE_URL}" >&2
  else
    if ! command -v pg_tmp >/dev/null; then
      echo "pg_tmp not found. Install it with: brew install ephemeralpg" >&2
      exit 1
    fi

    use_homebrew_postgres

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
    # authentication and would otherwise listen on every interface. It runs in
    # a session of its own: a server that stayed in the caller's process group
    # would die with the shell that asked for it, before the run that needs it
    # had finished. The printed URL is the same line it has always printed.
    #
    # A server that did not start ends the caller, even where `set -e` is off
    # (a call under `||` or `if`), so no run goes on without its own database.
    GTFS_PLANNER_TEST_DATABASE_URL=$(detach_capture pg_tmp -t -w "$timeout" -o "-c listen_addresses=127.0.0.1" ${datadir:+-d "$datadir"}) || {
      echo "pg_tmp could not start a server" >&2
      exit 1
    }
    export GTFS_PLANNER_TEST_DATABASE_URL

    if [ -n "$keep" ]; then
      echo "Postgres (pg_tmp, kept until idle at a ${timeout}s check): ${GTFS_PLANNER_TEST_DATABASE_URL}" >&2
      echo "Connect with: psql '${GTFS_PLANNER_TEST_DATABASE_URL}'" >&2
    else
      echo "Postgres (pg_tmp): ${GTFS_PLANNER_TEST_DATABASE_URL}" >&2
    fi
  fi
}

# stop_database <dir>
#
# Stops the server that start_database --datadir <dir> started and removes <dir>,
# using pg_tmp's own stop. Pass the same <dir> string. A server that is already
# gone is not an error. Returns once the server process has exited, since
# pg_tmp does not wait for it, so a caller can rely on nothing being left.
stop_database() {
  local dir=$1 pid pidfile output sleeper

  use_homebrew_postgres

  # start_database left a waiter that would stop the server at its next idle
  # check. Once the server is stopped here it has nothing to do: end it and its
  # sleep. Its command line is `pg_tmp -w <timeout> -d <dir> -p <port> stop`.
  # SIGKILL, because its EXIT trap runs `rm -r <dir>` on any other signal, which
  # would delete the data under a running server.
  for pid in $(pgrep -f "pg_tmp -w [0-9]+ -d ${dir} -p [0-9]+ stop$" || true); do
    sleeper=$(pgrep -P "$pid" || true)
    # shellcheck disable=SC2086 # at most one sleeper pid
    kill -KILL "$pid" $sleeper 2>/dev/null || true
  done

  if ! compgen -G "$dir/*/postmaster.pid" >/dev/null; then
    echo "Postgres (pg_tmp) already stopped: ${dir}" >&2
    return 0
  fi

  pidfile=$(compgen -G "$dir/*/postmaster.pid")
  pid=$(head -n 1 "$pidfile")

  # -w 0 skips pg_tmp's idle wait; without -p it does not wait for clients, and
  # pg_ctl's fast shutdown disconnects them. Its output is only for a failure.
  if ! output=$(pg_tmp -w 0 -d "$dir" stop 2>&1); then
    echo "$output" >&2
    echo "stop_database: pg_tmp could not stop ${dir}" >&2
    return 1
  fi

  for _ in $(seq 100); do
    ps -p "$pid" >/dev/null 2>&1 || break
    sleep 0.1
  done
  if ps -p "$pid" >/dev/null 2>&1; then
    echo "stop_database: server ${pid} in ${dir} is still running after 10s" >&2
    return 1
  fi

  echo "Postgres (pg_tmp) stopped: ${dir}" >&2
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
