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
import { basename, dirname, join, resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

import { ACCOUNTS } from "./accounts.mjs";
import { MUTATING, validateStep } from "./actions.mjs";
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

// The LiveView settle after an action: the same condition the browser tests
// wait for, bounded so a page that never reconnects does not hold a step. The
// wait is not fatal — a step that navigated somewhere without a LiveView is
// still a step the tester took and can see in the observation.
const LIVEVIEW_TIMEOUT_MS = 10_000;

// A short quiet window after the LiveView settles, so the observation reads
// the page the tester is looking at rather than a half-rendered one.
const DOM_QUIET_MS = 300;
const DOM_QUIET_MAX_MS = 3_000;

// An `ariaSnapshot` of a real page is long; the observation keeps a bounded
// prefix so one line of `steps.jsonl` stays readable, marked so a reader knows
// it is a prefix.
const SNAPSHOT_LIMIT = 6_000;

// How many names of the requested role an action failure lists, so a tester can
// correct the name instead of guessing.
const NEARBY_NAMES = 5;

// The folder a scenario's `Files` name, relative to the repository root. The
// names come from the journey page and the file system keeps them here, so an
// upload can only ever read a file this repository ships as a fixture.
const UPLOAD_FIXTURE_DIR = "test/fixtures/gtfs/ux_qa";

// An upload is tried this many times, because the failure it works around —
// a chooser whose input has no upload ref yet — is a race the page resolves by
// itself on a second attempt.
const UPLOAD_ATTEMPTS = 3;

// Bounded so an input that never gets a ref and an entry the page never lists
// both end the attempt instead of holding the step.
const UPLOAD_REF_TIMEOUT_MS = 10_000;
const UPLOAD_ENTRY_TIMEOUT_MS = 5_000;

const CAPTURE_DIGITS = 3;

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
    // Downloads this run has seen, each with its save in flight. A step
    // awaits them before it builds its observation, so a file the run reports
    // is a file on disk.
    downloads: [],
    // `attempt` counts every step attempt including rejected ones, and
    // `observedHrefs` is what a later `goto` may address: the start path plus
    // every same-origin link the driver has actually seen.
    attempt: 0,
    observedHrefs: new Set(),
    // The page's URL as the driver last read it, so a rejected step records
    // where the run was without asking the page anything.
    url: "",
    ready: false,
    setupError: null,
    shuttingDown: false
  };
}

export function attachListeners(state) {
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

  // The download is saved into the run's downloads folder. The event arrives
  // while a step is acting, so the save is recorded rather than awaited here;
  // the step awaits it before its observation, and the buffered event is what
  // puts the name in that step's record.
  page.on("download", download => {
    const name = download.suggestedFilename();
    const saved = join(state.session.run, "downloads", name);

    state.downloads.push({
      name,
      save: download.saveAs(saved).then(
        () => null,
        error => String(error?.message ?? error)
      )
    });
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
  state.url = page.url();
}

// ---------------------------------------------------------------------------
// One tester step
// ---------------------------------------------------------------------------

// The LiveView settle, the condition `waitForLiveView` uses in
// `assets/e2e/import_export.spec.js`. It runs after an action rather than as a
// test assertion, so a page with no LiveView on it is not an error here.
export async function waitForLiveView(page, { timeout = LIVEVIEW_TIMEOUT_MS } = {}) {
  await page.waitForSelector("[data-phx-main]", { state: "attached", timeout });

  await page.waitForFunction(
    () => {
      const main = document.querySelector("[data-phx-main]");

      return (
        main !== null &&
        main.classList.contains("phx-connected") &&
        !main.hasAttribute("data-phx-pending") &&
        window.liveSocket?.isConnected()
      );
    },
    undefined,
    { timeout }
  );
}

// The page's markup size, read for the quiet window. It is a named function so
// a caller — and a test double — can recognise it rather than re-implementing
// the probe.
export function bodyLength() {
  return document.body.innerHTML.length;
}

// A window in which the page's markup does not change, bounded so a page that
// never goes quiet does not hold the step.
export async function waitForDomQuiet(page, { quietMs = DOM_QUIET_MS, maxMs = DOM_QUIET_MAX_MS } = {}) {
  const deadline = Date.now() + maxMs;

  for (;;) {
    const before = await page.evaluate(bodyLength);

    await page.waitForTimeout(quietMs);

    if ((await page.evaluate(bodyLength)) === before) return;
    if (Date.now() >= deadline) return;
  }
}

// The settle that follows an action. `look` and `scroll` change nothing the
// server owns, so they are observed exactly as they are.
const SETTLING_ACTIONS = new Set(["look", "scroll"]);

async function settle(page, action) {
  if (SETTLING_ACTIONS.has(action)) return;

  await waitForLiveView(page).catch(() => {});
  await waitForDomQuiet(page).catch(() => {});
}

// The one locator a step addresses the page with: a role with an exact name,
// or exact text. Playwright's own matching decides whether that is one
// element or none, and a strict-mode violation is the tester's correction, not
// a harness failure.
export function targetLocator(page, step) {
  if (step.role !== undefined) {
    return page.getByRole(step.role, { name: step.name, exact: true });
  }

  return page.getByText(step.text, { exact: true });
}

// Up to five visible names of the same role, so a failed action tells the
// tester what the page does call the thing it asked for.
export async function nearbyNames(page, role) {
  try {
    const located = page.getByRole(role);
    const count = await located.count();
    const names = [];

    for (let index = 0; index < Math.min(count, NEARBY_NAMES); index += 1) {
      const name = await located
        .nth(index)
        .evaluate(element => (element.getAttribute("aria-label") ?? element.textContent ?? "").trim().split("\n")[0]);

      if (name !== "") names.push(name.slice(0, 80));
    }

    return names;
  } catch {
    return [];
  }
}

// The first line of the failure plus, when the step named a role, the names
// that role does carry. A full Playwright stack is noise to a tester reading
// one line of output.
export async function describeActionError(error, step, page) {
  const firstLine = String(error?.message ?? error).split("\n")[0].trim();
  const names = step?.role === undefined ? [] : await nearbyNames(page, step.role);

  if (names.length === 0) return firstLine;

  return `${firstLine} (${step.role} names here: ${names.join(", ")})`;
}

function baseUrlOf(session) {
  return `http://localhost:${session.port}`;
}

// The repository root, derived from this module's own path so an upload's file
// resolves the same whichever directory the driver was started in.
export function repositoryRoot() {
  return dirname(dirname(dirname(fileURLToPath(import.meta.url))));
}

// Resolves a scenario's `Files` name to the fixture it names. The name is
// checked rather than sanitised: a name carrying a path is refused, because a
// journey page names files and never names folders.
export function uploadFilePath(name, root = repositoryRoot()) {
  const folder = resolve(root, UPLOAD_FIXTURE_DIR);
  const path = resolve(folder, name);

  if (dirname(path) !== folder) {
    throw new Error(`upload --file ${name} is not a file of ${UPLOAD_FIXTURE_DIR}`);
  }

  return path;
}

// The chooser's input carrying a non-empty LiveView upload ref. A file set
// before this exists is dropped by the client with no error, which would read
// as tester confusion rather than as a harness race.
export function hasUploadRef(input) {
  const ref = input?.getAttribute("data-phx-upload-ref");

  return typeof ref === "string" && ref !== "";
}

// The file's own name appearing anywhere in the page text, which is how the
// page answers that it took the file. Reading text rather than a list keeps
// this independent of how either import page renders its entries.
export function pageTextIncludes(name) {
  return (document.body.innerText ?? "").includes(name);
}

// One upload attempt: open the chooser on the control the tester named, wait
// for the input to carry a ref, set the file, and confirm the page listed it.
async function uploadOnce(page, step, path) {
  // The event is awaited together with the click that raises it, so the two
  // are never ordered wrongly against each other.
  const opened = page.waitForEvent("filechooser");

  await targetLocator(page, step).click();

  const chooser = await opened;
  const input = await chooser.element();

  await page.waitForFunction(hasUploadRef, input, { timeout: UPLOAD_REF_TIMEOUT_MS });
  await chooser.setFiles(path);
  await page.waitForFunction(pageTextIncludes, basename(path), { timeout: UPLOAD_ENTRY_TIMEOUT_MS });
}

// The upload action. The step is ok once the page has listed the file, and is
// not ok — with the reason the tester can act on — once three attempts have
// each failed to produce that listing.
async function uploadFile(page, step) {
  const path = uploadFilePath(step.file);

  for (let attempt = 1; attempt <= UPLOAD_ATTEMPTS; attempt += 1) {
    try {
      await uploadOnce(page, step, path);

      return;
    } catch {
      // A chooser with no ref yet, or a file the page never listed, is
      // retried: each attempt clicks the control again, which opens a fresh
      // chooser with a fresh input.
    }
  }

  throw new Error(`the file name did not appear after ${UPLOAD_ATTEMPTS} attempts`);
}

// One executor per action. `upload` is the only one that opens a file chooser
// and the only one that retries.
const EXECUTORS = {
  click: (page, step) => targetLocator(page, step).click(),
  fill: (page, step) => page.getByLabel(step.label, { exact: true }).fill(step.value),
  select: (page, step) => page.getByLabel(step.label, { exact: true }).selectOption({ label: step.option }),
  upload: (page, step) => uploadFile(page, step),
  press: (page, step) => page.keyboard.press(step.key),
  goto: (page, step, { baseUrl }) => page.goto(new URL(step.path, baseUrl).href),
  back: page => page.goBack(),
  scroll: (page, step) => page.mouse.wheel(0, step.dy),
  look: () => {},
  wait: (page, step) => page.getByText(step.text).first().waitFor({ state: "visible", timeout: step.timeout * 1000 })
};

export function hasExecutor(action) {
  return Object.hasOwn(EXECUTORS, action);
}

// What the page shows, read in one round trip. The function is serialized into
// the page, so it stands alone and returns only plain data.
function readPageFacts() {
  const visible = element => {
    const style = window.getComputedStyle(element);

    return style.visibility !== "hidden" && style.display !== "none" && element.getClientRects().length > 0;
  };

  const text = element => (element.innerText ?? element.textContent ?? "").trim();

  const headings = [...document.querySelectorAll("h1, h2, h3")]
    .filter(visible)
    .map(text)
    .filter(value => value !== "");

  const announcements = [...document.querySelectorAll('[role="alert"], [role="status"]')]
    .filter(visible)
    .map(element => ({ role: element.getAttribute("role"), text: text(element) }))
    .filter(entry => entry.text !== "");

  const active = document.activeElement;
  const focused =
    active === null || active === document.body
      ? null
      : {
          role: active.getAttribute("role") ?? active.tagName.toLowerCase(),
          name: (active.getAttribute("aria-label") ?? active.textContent ?? "").trim().split("\n")[0]
        };

  const hrefs = [...document.querySelectorAll("a[href]")]
    .map(anchor => anchor.href)
    .filter(href => {
      try {
        return new URL(href).origin === location.origin;
      } catch {
        return false;
      }
    })
    .map(href => `${new URL(href).pathname}${new URL(href).search}`);

  return { headings, announcements, focused, hrefs };
}

export function trimSnapshot(text, limit = SNAPSHOT_LIMIT) {
  return text.length > limit ? `${text.slice(0, limit)} [truncated]` : text;
}

// The observation printed per step (contract C-4): where the page is, what it
// says, what it announced, what has focus, a bounded accessibility snapshot,
// the downloads this step produced, the errors the buffer drained, and the
// capture the review reads.
export async function buildObservation(page, { events, capture, hrefs = [] } = {}) {
  const facts = await page.evaluate(readPageFacts).catch(() => ({
    headings: [],
    announcements: [],
    focused: null,
    hrefs: []
  }));

  const url = new URL(page.url());
  const snapshot = await page
    .locator("body")
    .ariaSnapshot()
    .catch(() => "");

  return {
    url: `${url.pathname}${url.search}`,
    title: await page.title().catch(() => ""),
    headings: facts.headings,
    alerts: facts.announcements,
    focused: facts.focused,
    snapshot: trimSnapshot(snapshot),
    downloads: events?.downloads ?? [],
    consoleErrors: events?.consoleErrors ?? { count: 0, first: [] },
    httpErrors: events?.httpErrors ?? { count: 0, first: [] },
    screenshot: capture ?? null,
    hrefs: [...new Set([...hrefs, ...facts.hrefs])]
  };
}

// A recorded trail step carries no intent and no expectation (contract C-7), so
// a run that replays one passes the vocabulary's target rules with those two
// requirements filled in. Nothing else is skipped, and the record still logs
// what the step actually had.
function validatedFlags(flags, requireIntent) {
  if (requireIntent || !MUTATING.includes(flags?.action)) return flags;

  return { ...flags, intent: flags.intent ?? "replayed", expect: flags.expect ?? "replayed" };
}

function targetOf(step) {
  const { action, ...target } = step;

  return target;
}

// Awaits the save of every download seen so far and empties the list, so the
// observation a step builds reports files that are on disk rather than in
// flight. A save that failed is the step's error: a download the run cannot
// open is not a download it may report.
export async function drainDownloads(state) {
  const pending = state.downloads.splice(0, state.downloads.length);

  return Promise.all(
    pending.map(async download => ({ name: download.name, error: await download.save }))
  );
}

function capturePath(runDir, n) {
  return join(runDir, "captures", `s${String(n).padStart(CAPTURE_DIGITS, "0")}.png`);
}

// The single code path for a tester step: live steps and replay steps both
// come through here, so the vocabulary check, the settle, the record and the
// observation cannot drift apart. `requireIntent: false` is the replay shape.
export async function executeStep(state, { flags, requireIntent = true } = {}) {
  const { page, session, scenario, buffer } = state;

  state.attempt += 1;

  const n = state.attempt;
  const startedAt = Date.now();
  const at = new Date().toISOString();
  const urlBefore = state.url;
  const intent = typeof flags?.intent === "string" ? flags.intent : "";
  const expected = typeof flags?.expect === "string" ? flags.expect : "";

  const validation = validateStep(validatedFlags(flags, requireIntent), {
    attempt: n,
    startPath: scenario.startPath,
    observedHrefs: state.observedHrefs,
    files: scenario.files
  });

  // A rejected step is recorded and answered, and never reaches the browser.
  if (!validation.ok) {
    const record = appendRecord(session.run, {
      kind: "step",
      run: session.run,
      n,
      t: at,
      action: typeof flags?.action === "string" ? flags.action : "",
      target: null,
      intent,
      expected,
      urlBefore,
      urlAfter: urlBefore,
      ok: false,
      rejected: validation.reason,
      error: validation.reason,
      ms: Date.now() - startedAt,
      capture: null,
      consoleErrors: 0,
      httpErrors: 0,
      alerts: [],
      downloads: []
    });

    return { ok: false, code: 1, n, rejected: validation.reason, error: validation.reason, record, observation: null };
  }

  const step = validation.step;
  let error = null;

  if (!hasExecutor(step.action)) {
    error = `this driver does not execute ${step.action} yet`;
  } else {
    try {
      await EXECUTORS[step.action](page, step, { baseUrl: baseUrlOf(session) });
      await settle(page, step.action);
    } catch (thrown) {
      error = await describeActionError(thrown, step, page);
    }
  }

  // A download the run lost is a tester-visible failure, and it is decided
  // before the record is written so the record and its capture cannot disagree.
  for (const download of await drainDownloads(state)) {
    if (download.error !== null && error === null) {
      error = `the download ${download.name} did not save: ${download.error}`;
    }
  }

  // The events this step produced are drained after it acts, so the console and
  // network errors in the record and the observation are the ones since the
  // previous step.
  const events = buffer.drain();
  const wanted = capturePath(session.run, n);
  const captured = await page
    .screenshot({ path: wanted })
    .then(() => wanted, () => null);

  const observation = await buildObservation(page, { events, capture: captured });

  state.url = page.url();

  for (const href of observation.hrefs) state.observedHrefs.add(href);
  state.observedHrefs.add(observation.url);

  const record = appendRecord(session.run, {
    kind: "step",
    run: session.run,
    n,
    t: at,
    action: step.action,
    target: targetOf(step),
    intent,
    expected,
    urlBefore,
    urlAfter: observation.url,
    ok: error === null,
    rejected: false,
    error,
    ms: Date.now() - startedAt,
    capture: captured,
    consoleErrors: events.consoleErrors.count,
    httpErrors: events.httpErrors.count,
    alerts: observation.alerts,
    downloads: observation.downloads
  });

  return {
    ok: error === null,
    code: error === null ? 0 : 1,
    n,
    error,
    record,
    observation
  };
}

export function registerStep(registry, state) {
  registry.register("step", command => executeStep(state, { flags: command }));

  return registry;
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
  const registry = registerStep(registerBuiltins(createRegistry(), state), state);

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