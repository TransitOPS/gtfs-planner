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
// `open` starts the detached driver and waits for its sign-in, `step` acts as
// the tester and prints the observation, `note` and `finish` close the tester's
// side of the run, and `close` stops it. The commands that inspect a run
// afterwards work from its files and need no driver: `report` prints the
// proxies, `finalize` writes `result.json` from the check's exit code and
// `record` writes the replay trail of a run that passed. `replay` is the one
// inspection command that needs the driver again, because it re-runs the
// recorded steps through it.

import { execFileSync, spawn } from "node:child_process";
import {
  closeSync,
  existsSync,
  mkdirSync,
  openSync,
  readFileSync,
  renameSync,
  writeFileSync
} from "node:fs";
import { createConnection } from "node:net";
import { dirname, join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

import { COUNTED, MAX_STEPS } from "./actions.mjs";
import { readRecords } from "./driver.mjs";
import { STUB_PATH_PREFIXES } from "./events.mjs";
import { computeProxies } from "./metrics.mjs";
import { loadScenarios, selectScenarios } from "./scenario.mjs";
import {
  gitPrimary,
  readSession,
  replaysRoot,
  resultStatus,
  runDirName,
  runsRoot,
  socketPathFor,
  trailFileName,
  writeSession
} from "./session.mjs";

const HERE = dirname(fileURLToPath(import.meta.url));
const DRIVER = join(HERE, "driver.mjs");

// `open` waits this long for the driver's sign-in before it calls the run
// failed; Chromium launch plus a page load is seconds, and the launcher's own
// server wait is longer, so this is a bound rather than a guess.
const OPEN_TIMEOUT_MS = 90_000;

// A step gets a client deadline of its own: a `wait` step is allowed to hold
// for the seconds it asked for, and the settle after an action is bounded too,
// so the client adds a fixed allowance on top of whatever the step may wait.
const STEP_TIMEOUT_SLACK_MS = 30_000;
const STEP_TIMEOUT_MS = 60_000;

// The poll interval while `open` waits; a tool interval is not a deadline.
const OPEN_POLL_MS = 250;

// A replay is one long command: every step is a live step and a trail may
// wait for an import. The client's deadline is the sum of the waits the trail
// asked for plus an allowance per step, so a trail that waits does not get
// reported as a driver that hung.
const REPLAY_TIMEOUT_SLACK_MS = 60_000;

// The processes a run records in `session.json`. Nothing else is ever stopped.
const PROCESS_NAMES = ["phoenix", "driver"];

const USAGE = `usage: node assets/qa/drive.mjs <command> [options]

  scenario <JRNY-###/slug>
  init --scenario ID --port N [--db-url URL] [--java-path PATH] [--headed]
  set-pid --run DIR --which phoenix|driver --pid N
  open --run DIR [--headed] [--timeout S]
  step --run DIR <action> [target and value flags]
  note --run DIR [--about N|last] --observed T [--confusion none|mild|blocked]
  finish --run DIR --claim done|gave-up [--reason T] [--eyes host-vision|codex-relay|source-only]
  close --run DIR [--timeout S]
  report --run DIR
  finalize --run DIR --check-exit N --server-alive yes|no
  record --run DIR
  replay --run DIR --trail FILE`;

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
    case "step":
      return step(rest);
    case "note":
      return note(rest);
    case "finish":
      return finish(rest);
    case "close":
      return close(rest);
    case "report":
      return report(rest);
    case "finalize":
      return finalize(rest);
    case "record":
      return record(rest);
    case "replay":
      return replay(rest);
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

// One tester step, addressed the way a tester reads the page: an action, then
// role and name or text or label, and the value the step carries. The action
// is the first bare word; everything else is a flag the driver validates.
function step(argv) {
  const flags = parseFlags(argv);
  const { run: runDir } = flags;
  const action = flags._[0];

  if (runDir === undefined || action === undefined) {
    throw new Error("step needs --run and an action");
  }

  const session = readSession(runDir);
  // The action is the first bare word and is already in the command, so the
  // collected words are not sent a second time.
  const { run: _run, _: _words, ...rest } = flags;
  const command = { cmd: "step", run: runDir, action, ...rest };
  const requested = Number(rest.timeout);

  return sendCommand(session.socket, command, {
    timeoutMs:
      Number.isFinite(requested) && requested > 0
        ? requested * 1000 + STEP_TIMEOUT_SLACK_MS
        : STEP_TIMEOUT_MS
  });
}

// A note and a finish are the tester's own words: one says what they saw, the
// other says whether they believe the goal was reached. Both are thin clients;
// the driver owns the vocabularies and the records they write.
function note(argv) {
  return clientCommand(argv, "note", "note needs --run");
}

function finish(argv) {
  return clientCommand(argv, "finish", "finish needs --run");
}

function clientCommand(argv, cmd, usage) {
  const flags = parseFlags(argv);
  const { run: runDir } = flags;

  if (runDir === undefined) throw new Error(usage);

  const session = readSession(runDir);
  // The action is a bare word in `step`; these two carry only flags, so the
  // collected words are dropped rather than sent as an action.
  const { run: _run, _: _words, ...rest } = flags;

  return sendCommand(session.socket, { cmd, run: runDir, ...rest });
}

async function close(argv) {
  const flags = parseFlags(argv);
  const runDir = flags.run;

  if (runDir === undefined) throw new Error("close needs --run");

  const session = readSession(runDir);
  const timeoutMs = (Number(flags.timeout ?? 30) || 30) * 1000;

  return sendCommand(session.socket, { cmd: "close" }, { timeoutMs });
}

// The observation a tester reads after every step, one `key: value` line per
// field. A field with nothing in it says `none` rather than printing blank, so
// a transcript of a run reads the same whether or not the page had alerts or
// downloads. A rejected step reports the reason instead: it has no page to
// describe.
export function formatStepReply(reply) {
  const lines = [`step ${reply.n ?? "?"}: ${reply.ok === true ? "ok" : "not ok"}`];

  if (reply.rejected !== undefined) lines.push(`rejected: ${reply.rejected}`);
  if (reply.ok !== true && reply.rejected === undefined) lines.push(`error: ${reply.error ?? "unknown"}`);

  const observation = reply.observation;

  if (observation === undefined || observation === null) return `${lines.join("\n")}\n`;

  const values = {
    url: observation.url,
    title: observation.title,
    headings: (observation.headings ?? []).join(" | "),
    alerts: (observation.alerts ?? []).map(entry => `${entry.role}: ${entry.text}`).join(" | "),
    focused: observation.focused === null ? "" : `${observation.focused.role}: ${observation.focused.name}`,
    snapshot: observation.snapshot,
    downloads: (observation.downloads ?? []).join(" | "),
    consoleErrors: `${observation.consoleErrors?.count ?? 0}${
      (observation.consoleErrors?.first ?? []).length > 0
        ? ` (${observation.consoleErrors.first.join(" | ")})`
        : ""
    }`,
    httpErrors: `${observation.httpErrors?.count ?? 0}${
      (observation.httpErrors?.first ?? []).length > 0 ? ` (${observation.httpErrors.first.join(" | ")})` : ""
    }`
  };

  for (const [key, value] of Object.entries(values)) {
    lines.push(`${key}: ${value === "" || value === undefined ? "none" : value}`);
  }

  lines.push(`screenshot: ${observation.screenshot ?? "none"}`);

  return `${lines.join("\n")}\n`;
}

// The scenario this run was created for, resolved from the journey pages
// through the run's own `session.json` (contract C-1).
function scenarioOf(session) {
  return selectScenarios(loadScenarios(), session.scenario)[0];
}

function proxiesOf(runDir, scenario) {
  return computeProxies(readRecords(runDir), {
    entryRoute: scenario.entryRoute,
    startPath: scenario.startPath
  });
}

// The proxies a rating reads, printed as JSON. It works from the step log, so
// it answers for a run whose driver is gone.
function report(argv) {
  const flags = parseFlags(argv);
  const { run: runDir } = flags;

  if (runDir === undefined) throw new Error("report needs --run");

  const session = readSession(runDir);

  return { ok: true, code: 0, proxies: proxiesOf(runDir, scenarioOf(session)) };
}

// The check's own printed JSON, absent when it crashed before printing. Its
// `pass` is not read here: the exit code and the server decide the outcome
// (rule R2), so a check that printed `true` and exited 2 is a harness error.
function readCheck(runDir) {
  const path = join(runDir, "check.json");

  if (!existsSync(path)) return null;

  return JSON.parse(readFileSync(path, "utf8"));
}

// `result.json` (contract C-6). The status and the pass come from
// `resultStatus`; the tester's claim is copied into the file and is never an
// input to either.
export function buildResult({ session, scenario, records, check, checkExit, serverAlive, finishedAt }) {
  const finish = records.find(record => record.kind === "finish") ?? null;
  const { status, pass } = resultStatus(checkExit, serverAlive);

  return {
    run: session.run,
    scenario: session.scenario,
    status,
    check: {
      id: check?.id ?? scenario.successCheck.id,
      pass,
      observations: check?.observations ?? []
    },
    claim: finish?.claim ?? null,
    reason: finish?.reason ?? null,
    eyes: finish?.eyes ?? null,
    referenceActions: scenario.referenceActions,
    proxies: computeProxies(records, { entryRoute: scenario.entryRoute, startPath: scenario.startPath }),
    stubExclusions: [...STUB_PATH_PREFIXES],
    commit: session.commit,
    dirty: session.dirty,
    startedAt: session.startedAt,
    finishedAt
  };
}

function finalize(argv) {
  const flags = parseFlags(argv);
  const { run: runDir } = flags;

  if (runDir === undefined || flags["check-exit"] === undefined) {
    throw new Error("finalize needs --run and --check-exit");
  }

  const checkExit = Number(flags["check-exit"]);
  const serverAlive = flags["server-alive"] !== "no";
  const session = readSession(runDir);
  const scenario = scenarioOf(session);
  const records = readRecords(runDir);
  const result = buildResult({
    session,
    scenario,
    records,
    check: readCheck(runDir),
    checkExit,
    serverAlive,
    finishedAt: new Date().toISOString()
  });

  const path = join(runDir, "result.json");

  writeFileSync(path, `${JSON.stringify(result, null, 2)}\n`, "utf8");

  return { ok: true, code: 0, result: path, status: result.status };
}

// The proxies of `report`, printed as the bare object rather than wrapped in a
// reply, because that is what the launcher pipes into the rest of the run.
export function formatReportReply(reply) {
  return `${JSON.stringify(reply.proxies ?? null, null, 2)}\n`;
}

// The trail's steps (contract C-7): the ok action steps of a passing run, in
// order, each carrying exactly the target the vocabulary produced. `look` and
// `scroll` are left out because they change nothing the application can drift
// on, `wait` is kept because an import or a validation is asynchronous and a
// trail that dropped the wait would fail on a correct flow (rule R7), and a
// step a replay produced is left out because a replay is not an exploration.
const TRAIL_ACTIONS = [...COUNTED, "wait"];

// The trail of one run. The scenario, the run it came from and the commit it
// was recorded at are what a reader needs to know the path is being replayed
// against that state.
export function buildTrail({ session, records }) {
  return {
    scenario: session.scenario,
    recordedFrom: session.run,
    commit: session.commit ?? null,
    steps: records
      .filter(
        record =>
          record.kind === "step" &&
          record.ok === true &&
          TRAIL_ACTIONS.includes(record.action) &&
          record.replay !== true
      )
      .map(record => ({ action: record.action, ...record.target }))
  };
}

// Written through a temporary file in the same folder and renamed, so a reader
// never sees a half-written trail and a replay can never load one.
function writeJsonAtomic(path, value) {
  const temporary = `${path}.${process.pid}.tmp`;

  mkdirSync(dirname(path), { recursive: true });
  writeFileSync(temporary, `${JSON.stringify(value, null, 2)}\n`, "utf8");
  renameSync(temporary, path);

  return path;
}

// `record` writes the replay trail of a run whose check passed. Only a
// completed run is recorded: a trail built from a run that did not reach its
// goal would replay a path the application never really took, and its drift
// would say nothing (rule R9).
function record(argv) {
  const flags = parseFlags(argv);
  const { run: runDir } = flags;

  if (runDir === undefined) throw new Error("record needs --run");

  const session = readSession(runDir);
  const resultPath = join(runDir, "result.json");

  if (!existsSync(resultPath)) {
    throw new Error(`record needs ${resultPath}, which finalize writes`);
  }

  const result = JSON.parse(readFileSync(resultPath, "utf8"));

  if (result.status !== "completed") {
    return failure(`the run is ${result.status}, so no trail is recorded: only a passing run is replayed`, 1);
  }

  const trail = buildTrail({ session, records: readRecords(runDir) });
  const path = writeJsonAtomic(
    join(replaysRoot(gitPrimary()), trailFileName(session.scenario)),
    trail
  );

  return { ok: true, code: 0, trail: path, steps: trail.steps.length };
}

// `replay` hands a trail to the run's driver. A trail for another scenario is
// a usage error rather than a drift: the steps would be answered by a page the
// scenario never visits, so the failure would name a step that never drifted.
function replay(argv) {
  const flags = parseFlags(argv);
  const { run: runDir } = flags;

  if (runDir === undefined || flags.trail === undefined) {
    throw new Error("replay needs --run and --trail");
  }

  const session = readSession(runDir);
  const trail = JSON.parse(readFileSync(flags.trail, "utf8"));

  if (trail?.scenario !== session.scenario) {
    throw new Error(
      `the trail is for "${trail?.scenario ?? "no scenario"}" but this run is ${session.scenario}`
    );
  }

  const waits = (trail.steps ?? [])
    .filter(step => step.action === "wait")
    .reduce((total, step) => total + (Number(step.timeout) || 30) * 1000, 0);

  return sendCommand(
    session.socket,
    { cmd: "replay", run: runDir, trail },
    { timeoutMs: waits + (trail.steps?.length ?? 0) * STEP_TIMEOUT_SLACK_MS + REPLAY_TIMEOUT_SLACK_MS }
  );
}

// The replay's own line. A drift names the step, the error and the screenshot,
// because the whole value of a replay is knowing which step stopped; a clean
// replay says how many steps ran and what it removed.
export function formatReplayReply(reply) {
  if (reply.ok !== true) {
    const shot = reply.screenshot ? ` (screenshot: ${reply.screenshot})` : "";

    return `drift at step ${reply.failedStep ?? "?"}: ${reply.error ?? "unknown"}${shot}\n`;
  }

  const pruned = reply.pruned ?? [];
  const removed = pruned.length === 0 ? "" : `; pruned ${pruned.length} stale capture${pruned.length === 1 ? "" : "s"}`;

  return `replay ok: ${reply.steps} steps, no drift${removed}\n`;
}

const invokedDirectly =
  process.argv[1] !== undefined && import.meta.url === pathToFileURL(process.argv[1]).href;

if (invokedDirectly) {
  main(process.argv.slice(2))
    .then(reply => {
      process.stdout.write(
        process.argv[2] === "step"
          ? formatStepReply(reply)
          : process.argv[2] === "report"
            ? formatReportReply(reply)
            : process.argv[2] === "replay"
              ? formatReplayReply(reply)
              : `${JSON.stringify(reply)}\n`
      );
      process.exit(typeof reply.code === "number" ? reply.code : reply.ok === true ? 0 : 2);
    })
    .catch(error => {
      process.stdout.write(`${JSON.stringify(failure(error))}\n`);
      process.exit(2);
    });
}