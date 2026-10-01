#!/usr/bin/env node
// The client side of the tester harness (contract C-2).
//
// `bin/ux-qa` calls these subcommands; every one of them except `open` is a
// thin client that writes one JSON line to the resident driver's socket and
// prints the reply. The reply carries the process exit code the launcher
// returns, so the shell script never has to interpret a driver's answer.
//
// The commands here cover a run's lifecycle around the driver: `scenario`
// prints the scenario the launcher is about to run, `init` creates the run
// directory and its `session.json`, `set-pid` records a process this run owns,
// `open` starts the detached driver and waits for its sign-in, and `close`
// stops it. The commands that act as a tester arrive with the driver's own
// command table.

import { execFileSync, spawn } from "node:child_process";
import { closeSync, openSync } from "node:fs";
import { createConnection } from "node:net";
import { dirname, join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

import { MAX_STEPS } from "./actions.mjs";
import { loadScenarios, selectScenarios } from "./scenario.mjs";
import { gitPrimary, readSession, runDirName, runsRoot, socketPathFor, writeSession } from "./session.mjs";

const HERE = dirname(fileURLToPath(import.meta.url));
const DRIVER = join(HERE, "driver.mjs");

// `open` waits this long for the driver's sign-in before it calls the run
// failed; Chromium launch plus a page load is seconds, and the launcher's own
// server wait is longer, so this is a bound rather than a guess.
const OPEN_TIMEOUT_MS = 90_000;

// The poll interval while `open` waits; a tool interval is not a deadline.
const OPEN_POLL_MS = 250;

// The processes a run records in `session.json`. Nothing else is ever stopped.
const PROCESS_NAMES = ["phoenix", "driver"];

const USAGE = `usage: node assets/qa/drive.mjs <command> [options]

  scenario <JRNY-###/slug>
  init --scenario ID --port N [--db-url URL] [--java-path PATH] [--headed]
  set-pid --run DIR --which phoenix|driver --pid N
  open --run DIR [--headed] [--timeout S]
  close --run DIR [--timeout S]`;

// `--flag value` pairs, `--flag` booleans, and bare words collected as `_`.
export function parseFlags(argv, booleans = []) {
  const flags = { _: [] };

  for (let index = 0; index < argv.length; index += 1) {
    const token = argv[index];

    if (!token.startsWith("--")) {
      flags._.push(token);
      continue;
    }

    const name = token.slice(2);

    if (booleans.includes(name)) {
      flags[name] = true;
      continue;
    }

    flags[name] = argv[index + 1];
    index += 1;
  }

  return flags;
}

function failure(error, code = 2) {
  return { ok: false, code, error: String(error?.message ?? error) };
}

// One connection, one command line, one reply line. A socket that does not
// answer inside the deadline is a harness error rather than a hung run, so the
// launcher can fall back to the recorded pid.
export function sendCommand(socketPath, command, { timeoutMs = 30_000 } = {}) {
  return new Promise(resolve => {
    const connection = createConnection(socketPath);
    let pending = "";
    let settled = false;

    const finish = reply => {
      if (settled) return;

      settled = true;
      connection.end();
      connection.destroy();
      resolve(reply);
    };

    connection.setTimeout(timeoutMs);
    connection.on("connect", () => connection.write(`${JSON.stringify(command)}\n`));
    connection.on("data", chunk => {
      pending += chunk;

      const breakAt = pending.indexOf("\n");

      if (breakAt !== -1) {
        try {
          finish(JSON.parse(pending.slice(0, breakAt)));
        } catch {
          finish(failure("the driver replied with something that is not JSON"));
        }
      }
    });
    connection.on("timeout", () => finish(failure(`the driver at ${socketPath} did not answer`)));
    connection.on("error", error => finish(failure(error)));
  });
}

// The commit and whether the working tree was dirty when the run started; both
// are recorded in `session.json` so a result can be tied to a state.
function gitState() {
  const commit = execFileSync("git", ["rev-parse", "HEAD"], { encoding: "utf8" }).trim();
  const dirty = execFileSync("git", ["status", "--porcelain"], { encoding: "utf8" }).trim() !== "";

  return { commit, dirty };
}

async function main(argv) {
  const [command, ...rest] = argv;

  switch (command) {
    case "scenario":
      return scenario(rest);
    case "init":
      return init(rest);
    case "set-pid":
      return setPid(rest);
    case "open":
      return open(rest);
    case "close":
      return close(rest);
    case undefined:
      throw new Error(USAGE);
    default:
      throw new Error(`unknown command "${command}"; ${USAGE}`);
  }
}

function scenario(argv) {
  const flags = parseFlags(argv, ["headed"]);
  const id = flags._[0];

  if (id === undefined) throw new Error("scenario needs a scenario ID");

  const [found] = selectScenarios(loadScenarios(), id);

  return { ok: true, code: 0, scenario: found };
}

function init(argv) {
  const flags = parseFlags(argv, ["headed"]);
  const { scenario: id, port } = flags;

  if (id === undefined || port === undefined) {
    throw new Error("init needs --scenario and --port");
  }

  // The scenario is resolved here so `up` cannot create a run directory for an
  // ID no journey page declares.
  const [scenario] = selectScenarios(loadScenarios(), id);

  const runDir = join(runsRoot(gitPrimary()), runDirName(new Date(), scenario.id));
  const { commit, dirty } = gitState();

  writeSession(runDir, {
    run: runDir,
    scenario: scenario.id,
    port: Number(port),
    socket: socketPathFor(runDir),
    dbUrl: flags["db-url"] ?? null,
    pids: {},
    commit,
    dirty,
    startedAt: new Date().toISOString(),
    maxSteps: MAX_STEPS,
    javaPath: flags["java-path"] ?? null
  });

  return { ok: true, code: 0, run: runDir, socket: socketPathFor(runDir) };
}

function setPid(argv) {
  const flags = parseFlags(argv);
  const { run: runDir, which, pid } = flags;

  if (runDir === undefined || which === undefined || pid === undefined) {
    throw new Error("set-pid needs --run, --which and --pid");
  }

  if (!PROCESS_NAMES.includes(which)) {
    throw new Error(`--which must be one of ${PROCESS_NAMES.join(", ")}`);
  }

  const session = readSession(runDir);
  const pids = { ...session.pids, [which]: Number(pid) };

  writeSession(runDir, { ...session, pids });

  return { ok: true, code: 0, pids };
}

// Starts the driver detached so it outlives this process, then waits for its
// sign-in. The launcher records the printed pid with `set-pid`; the driver
// never writes `session.json` itself, so the launcher stays the only writer of
// the run's own record.
async function open(argv) {
  const flags = parseFlags(argv, ["headed"]);
  const runDir = flags.run;

  if (runDir === undefined) throw new Error("open needs --run");

  const session = readSession(runDir);
  const deadlineMs = (Number(flags.timeout ?? OPEN_TIMEOUT_MS / 1000) || OPEN_TIMEOUT_MS / 1000) * 1000;
  const deadline = Date.now() + deadlineMs;

  const log = openSync(join(runDir, "driver.log"), "a");

  try {
    const child = spawn(
      process.execPath,
      [DRIVER, "--run", runDir, ...(flags.headed === true ? ["--headed"] : [])],
      { detached: true, stdio: ["ignore", log, log] }
    );

    child.unref();

    // The driver answers `status` before it has signed in and reports `ready`
    // once it has, so a launcher that times out here learns the run is not
    // going to happen rather than blocking on a browser that never opened.
    let lastError = "the driver has not answered yet";

    for (;;) {
      const reply = await sendCommand(session.socket, { cmd: "status" }, { timeoutMs: 5_000 });

      if (reply.ok === true && reply.ready === true) {
        return { ok: true, code: 0, pid: child.pid, socket: session.socket, setup: reply.setup };
      }

      if (reply.ok === true && reply.setup?.error) {
        return failure(`the driver signed in unsuccessfully: ${reply.setup.error}`);
      }

      if (reply.ok !== true) lastError = reply.error;

      if (Date.now() >= deadline) {
        // A driver that died before signing in never answers, so the last
        // error it left is what the run's `driver.log` explains.
        return failure(
          `the driver at ${session.socket} was not ready within ${deadlineMs / 1000}s: ${lastError}`
        );
      }

      await new Promise(resolve => setTimeout(resolve, OPEN_POLL_MS));
    }
  } finally {
    closeSync(log);
  }
}

async function close(argv) {
  const flags = parseFlags(argv);
  const runDir = flags.run;

  if (runDir === undefined) throw new Error("close needs --run");

  const session = readSession(runDir);
  const timeoutMs = (Number(flags.timeout ?? 30) || 30) * 1000;

  return sendCommand(session.socket, { cmd: "close" }, { timeoutMs });
}

const invokedDirectly =
  process.argv[1] !== undefined && import.meta.url === pathToFileURL(process.argv[1]).href;

if (invokedDirectly) {
  main(process.argv.slice(2))
    .then(reply => {
      process.stdout.write(`${JSON.stringify(reply)}\n`);
      process.exit(typeof reply.code === "number" ? reply.code : reply.ok === true ? 0 : 2);
    })
    .catch(error => {
      process.stdout.write(`${JSON.stringify(failure(error))}\n`);
      process.exit(2);
    });
}