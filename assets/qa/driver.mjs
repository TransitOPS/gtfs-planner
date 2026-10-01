// The resident driver for one tester run (contracts C-4 and C-5).
//
// One process owns Chromium, one context and one page for the whole run: the
// browser survives between commands, so console, page-error, failed-request,
// response-status, dialog and download events that arrive while nobody is
// acting are buffered in `events.mjs` and drained into the next record instead
// of being lost. The driver signs the scenario's account in once (recorded as
// a `setup` line, never a scored step), writes the tester's brief, listens on
// the run's Unix socket and answers one JSON command per connection.
//
// The command table is a registry so the later steps that add commands add
// entries rather than rewrite the loop. `status` and `close` are the two the
// launcher needs before any tester step exists; the step, note, finish and
// replay commands are registered beside them.
//
// Playwright is imported inside `startBrowser` so that importing this module
// — the parser, the registry and the command loop — never needs the browser
// package to be installed.

import { appendFileSync, existsSync, mkdirSync, rmSync, writeFileSync } from "node:fs";
import { createServer, connect } from "node:net";
import { join } from "node:path";
import { pathToFileURL } from "node:url";

import { ACCOUNTS } from "./accounts.mjs";
import { EventBuffer } from "./events.mjs";
import { loadScenarios, selectScenarios, briefText } from "./scenario.mjs";
import { readSession } from "./session.mjs";

// The device viewport every tester run uses; the review reads captures at this
// size, so a capture taken elsewhere is not comparable.
export const VIEWPORT = { width: 1280, height: 800 };

// The sign-in the driver performs for itself. These selectors are the driver's
// own, never a tester's target: the tester vocabulary is role, label and text.
const LOGIN_PATH = "/users/log_in";
const LOGIN_EMAIL = "#login-email";
const LOGIN_PASSWORD = "#login-password";
const LOGIN_SUBMIT = "#login-submit";

const SIGN_IN_TIMEOUT_MS = 30_000;

const DRIVER_USAGE = "usage: node assets/qa/driver.mjs --run <run dir> [--headed]";

// The run's own artifacts, all under the run directory the launcher resolved.
export function stepsPath(runDir) {
  return join(runDir, "steps.jsonl");
}

// One JSON object per line, appended in execution order (contract C-5). A
// record is flushed by the append itself, so a driver that is killed mid-run
// leaves every record it had already made.
export function appendRecord(runDir, record) {
  appendFileSync(stepsPath(runDir), `${JSON.stringify(record)}\n`, "utf8");

  return record;
}

// The sign-in line: a `setup` record carrying no step number, because signing
// in is the harness's work and never a scored tester step.
export function setupRecord(run, ok, at = new Date().toISOString()) {
  return { kind: "setup", run, t: at, action: "sign-in", ok };
}

// `--run` is required and names the run directory; `--headed` shows the window.
export function parseDriverArgs(argv) {
  const args = { runDir: null, headed: false };

  for (let index = 0; index < argv.length; index += 1) {
    const token = argv[index];

    if (token === "--headed") {
      args.headed = true;
    } else if (token === "--run") {
      args.runDir = argv[index + 1];
      index += 1;
    } else {
      throw new Error(`unknown argument "${token}"; ${DRIVER_USAGE}`);
    }
  }

  if (args.runDir === null || args.runDir === "") {
    throw new Error(`--run is required; ${DRIVER_USAGE}`);
  }

  return args;
}

// The command table. A later command is one `register` call, so the socket
// loop, the reply shape and the failure handling stay in one place.
export function createRegistry() {
  const handlers = new Map();

  return {
    register(command, handler) {
      handlers.set(command, handler);
      return this;
    },
    has(command) {
      return handlers.has(command);
    },
    get(command) {
      return handlers.get(command);
    },
    commands() {
      return [...handlers.keys()];
    }
  };
}

export function ok(payload = {}) {
  return { ok: true, code: 0, ...payload };
}

// Every failure a driver can report is a harness error (exit 2) unless the
// handler says otherwise: a rejected tester step is a run outcome (exit 1) and
// its handler returns its own code.
export function failure(error, code = 2) {
  return { ok: false, code, error: String(error?.message ?? error) };
}

// Resolves one command line into one reply. A malformed line, an unknown
// command and a throwing handler all answer rather than kill the socket, so a
// bad command never takes the run's browser down with it.
export async function handleLine(line, registry) {
  let command;

  try {
    command = JSON.parse(line);
  } catch {
    return failure("a command is one JSON object per line");
  }

  const name = command?.cmd;

  if (typeof name !== "string" || !registry.has(name)) {
    return failure(`unknown command "${name ?? ""}"; this driver answers ${registry
      .commands()
      .join(", ")}`);
  }

  try {
    return await registry.get(name)(command);
  } catch (error) {
    return failure(error);
  }
}

// A socket file outlives a driver that was killed rather than closed, so the
// path can be taken by a file nothing is listening on. Probing it first keeps
// the two apart: a driver that answers is a run that already has a browser and
// is refused, and a path that refuses the connection is a leftover and is
// removed. The path is derived from the run directory, so only this run's own
// socket is ever touched.
export async function prepareSocketPath(
  socketPath,
  { exists = existsSync, probe = probeSocket } = {}
) {
  if (!exists(socketPath)) return false;

  if (await probe(socketPath)) {
    throw new Error(`a driver is already listening on ${socketPath}`);
  }

  rmSync(socketPath, { force: true });

  return true;
}

// `true` when something answers on the path, `false` when nothing does.
export function probeSocket(socketPath, timeoutMs = 500) {
  return new Promise(resolve => {
    const socket = connect(socketPath);
    let settled = false;

    const settle = alive => {
      if (settled) return;

      settled = true;
      socket.destroy();
      resolve(alive);
    };

    socket.setTimeout(timeoutMs);
    socket.on("connect", () => settle(true));
    socket.on("timeout", () => settle(false));
    socket.on("error", () => settle(false));
  });
}

// The socket server: one connection per command, one reply line per command
// line. Commands on a connection run in the order they arrived, so a client
// that pipelines two commands cannot interleave them.
export function createCommandServer({ socketPath, registry }) {
  const server = createServer(connection => {
    connection.setEncoding("utf8");

    let pending = "";
    let queue = Promise.resolve();

    connection.on("data", chunk => {
      pending += chunk;

      let breakAt = pending.indexOf("\n");

      while (breakAt !== -1) {
        const line = pending.slice(0, breakAt);
        pending = pending.slice(breakAt + 1);
        breakAt = pending.indexOf("\n");

        if (line.trim() === "") continue;

        queue = queue.then(async () => {
          const reply = await handleLine(line, registry);

          connection.write(`${JSON.stringify(reply)}\n`);
        });
      }
    });

    connection.on("error", () => connection.destroy());
  });

  server.listen(socketPath);

  return server;
}

// The state one driver holds for its run: the browser, the page, the buffered
// events and whether the sign-in completed.
function createState({ session, scenario }) {
  return {
    session,
    scenario,
    browser: null,
    context: null,
    page: null,
    buffer: new EventBuffer(),
    downloads: [],
    ready: false,
    setupError: null,
    shuttingDown: false
  };
}

function attachListeners(state) {
  const { page, buffer } = state;

  page.on("console", message => {
    buffer.push({
      type: "console",
      level: message.type(),
      text: message.text(),
      url: page.url()
    });
  });

  page.on("pageerror", error => {
    buffer.push({ type: "pageerror", text: error.message, url: page.url() });
  });

  page.on("requestfailed", request => {
    buffer.push({
      type: "requestfailed",
      url: request.url(),
      resourceType: request.resourceType()
    });
  });

  page.on("response", response => {
    buffer.push({
      type: "response",
      status: response.status(),
      url: response.url(),
      resourceType: response.request().resourceType()
    });
  });

  page.on("dialog", dialog => {
    buffer.push({ type: "dialog", message: dialog.message() });
  });

  // The download itself is saved by the command that awaits it; the event is
  // buffered here so the step record can name it even if nothing awaited it.
  page.on("download", download => {
    const name = download.suggestedFilename();

    state.downloads.push(download);
    buffer.push({ type: "download", name });
  });
}

async function signIn(state, baseUrl) {
  const { page } = state;
  const account = ACCOUNTS[state.scenario.account];

  if (account === undefined) {
    throw new Error(`the scenario names account "${state.scenario.account}", which accounts.mjs does not define`);
  }

  await page.goto(`${baseUrl}${LOGIN_PATH}`);
  await page.fill(LOGIN_EMAIL, account.email);
  await page.fill(LOGIN_PASSWORD, account.password);
  await page.click(LOGIN_SUBMIT);
  // A failed sign-in stays on the login page, so leaving it is the evidence
  // that the account reached the application.
  await page.waitForURL(url => !url.pathname.startsWith(LOGIN_PATH), {
    timeout: SIGN_IN_TIMEOUT_MS
  });
}

async function startBrowser(state, { baseUrl, headed }) {
  const { chromium } = await import("@playwright/test");

  state.browser = await chromium.launch({ headless: !headed });
  state.context = await state.browser.newContext({ viewport: VIEWPORT });
  state.page = await state.context.newPage();

  attachListeners(state);

  let signedIn = false;

  try {
    await signIn(state, baseUrl);
    signedIn = true;
  } catch (error) {
    state.setupError = error;
  } finally {
    appendRecord(state.session.run, setupRecord(state.session.run, signedIn));
  }

  state.ready = signedIn;
}

async function shutdown(state, server) {
  if (state.shuttingDown) return;

  state.shuttingDown = true;
  state.ready = false;

  if (state.context !== null) await state.context.close().catch(() => {});
  if (state.browser !== null) await state.browser.close().catch(() => {});

  rmSync(state.session.socket, { force: true });
  server.close();
}

// `status` is what `drive.mjs open` waits on: it answers as soon as the socket
// is listening and reports `ready` only once the sign-in has landed, so a
// failed sign-in surfaces as an explicit error instead of a later timeout.
function registerBuiltins(registry, state) {
  registry.register("status", () =>
    ok({
      pid: process.pid,
      socket: state.session.socket,
      run: state.session.run,
      scenario: state.session.scenario,
      ready: state.ready,
      setup: { ok: state.ready, error: state.setupError?.message ?? null }
    })
  );

  registry.register("close", () => {
    // The reply has to reach the client before the socket disappears, so the
    // teardown runs on the next turn of the loop rather than before the write.
    setTimeout(() => {
      shutdown(state, state.server).then(
        () => process.exit(0),
        () => process.exit(2)
      );
    }, 50);

    return ok({ closed: true });
  });

  return registry;
}

export async function run(argv) {
  const { runDir, headed } = parseDriverArgs(argv);
  const session = readSession(runDir);
  const scenario = selectScenarios(loadScenarios(), session.scenario)[0];

  mkdirSync(join(runDir, "captures"), { recursive: true });
  mkdirSync(join(runDir, "downloads"), { recursive: true });
  writeFileSync(join(runDir, "brief.md"), briefText(scenario), "utf8");

  const state = createState({ session, scenario });
  const registry = registerBuiltins(createRegistry(), state);

  await prepareSocketPath(session.socket);
  state.server = createCommandServer({ socketPath: session.socket, registry });

  const stop = () => {
    shutdown(state, state.server).then(
      () => process.exit(0),
      () => process.exit(2)
    );
  };

  process.on("SIGINT", stop);
  process.on("SIGTERM", stop);

  await startBrowser(state, { baseUrl: `http://localhost:${session.port}`, headed });
}

const invokedDirectly =
  process.argv[1] !== undefined && import.meta.url === pathToFileURL(process.argv[1]).href;

if (invokedDirectly) {
  run(process.argv.slice(2)).catch(error => {
    process.stderr.write(`${error?.stack ?? error}\n`);
    process.exit(2);
  });
}