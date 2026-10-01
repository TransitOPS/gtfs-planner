// Where one tester run lives and how its outcome is rated (rules R2 and R4,
// contracts C-3 and C-6).
//
// A run writes under the primary checkout's `.specs/`, never inside a
// worktree: `git rev-parse --git-common-dir` names the primary `.git` from any
// worktree, so the run directory is the same one whichever checkout started
// it. That resolution, the run directory name, the driver socket path and the
// three-valued result status all live here so the launcher, the driver and
// `result.json` cannot disagree about any of them.
//
// Naming and status mapping are pure; `gitPrimary`, `readSession` and
// `writeSession` are the only functions that touch the outside world, and the
// last one replaces its file by rename so a reader never sees a half-written
// `session.json`.

import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import { mkdirSync, readFileSync, renameSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";

// The file the launcher and the driver both read and write.
export const SESSION_FILE = "session.json";

// A Unix socket path has to stay under the platform limit; the run directory is
// long and the socket cannot live inside it.
export const SOCKET_PATH_LIMIT = 104;

const SOCKET_HASH_LENGTH = 8;

// `result.json.status` is three-valued and `check.pass` is `null` exactly when
// the run could not be judged, so a crashed harness is never rated.
const HARNESS_ERROR = { status: "harness-error", pass: null };

// The primary checkout is the directory holding the `.git` that
// `git rev-parse --git-common-dir` reports. In a worktree that path already
// points at the primary `.git`, so no worktree special case is needed here.
export function primaryCheckout(gitCommonDir) {
  return dirname(gitCommonDir);
}

// Resolves the primary checkout for the repository the command runs in.
export function gitPrimary(cwd = process.cwd()) {
  const commonDir = execFileSync(
    "git",
    ["rev-parse", "--path-format=absolute", "--git-common-dir"],
    { cwd, encoding: "utf8" }
  ).trim();

  return primaryCheckout(commonDir);
}

// `<primary>/.specs/ux-qa/runs` holds every run directory. Nothing the harness
// writes belongs anywhere else.
export function runsRoot(primary) {
  return join(primary, ".specs", "ux-qa", "runs");
}

// `20260930T190805Z-JRNY-001-import`: a UTC stamp so runs sort chronologically,
// then the scenario ID with its slash replaced.
export function runDirName(date, scenarioId) {
  const stamp = date.toISOString().replace(/[-:.]/g, "").replace(/(\d{3})Z$/, "Z");

  return `${stamp}-${scenarioId.replaceAll("/", "-")}`;
}

// `<primary>/.specs/ux-qa/replays` holds the trail a passing run records
// (rule R9). It resolves beside the runs root so the replay client, the driver
// and the launcher cannot disagree about where a trail lives.
export function replaysRoot(primary) {
  return join(primary, ".specs", "ux-qa", "replays");
}

// `<primary>/.specs/ux-qa/reference-trails` holds the authored positive control
// of each scenario (rule R17). It sits beside `replaysRoot` so the launcher's
// `selfcheck` and whatever writes a trail later cannot disagree about the path.
export function referenceTrailsRoot(primary) {
  return join(primary, ".specs", "ux-qa", "reference-trails");
}

// `JRNY-001-import.json`: a trail is named by its scenario ID with the slash
// replaced, the same shape a run directory name takes.
export function trailFileName(scenarioId) {
  return `${scenarioId.replaceAll("/", "-")}.json`;
}

export function sessionPath(runDir) {
  return join(runDir, SESSION_FILE);
}

export function readSession(runDir) {
  return JSON.parse(readFileSync(sessionPath(runDir), "utf8"));
}

// Written through a temporary file in the same directory and renamed, so a
// concurrent reader sees either the old session or the new one and never a
// truncated file.
export function writeSession(runDir, session) {
  mkdirSync(runDir, { recursive: true });

  const target = sessionPath(runDir);
  const temporary = `${target}.${process.pid}.tmp`;

  writeFileSync(temporary, `${JSON.stringify(session, null, 2)}\n`, "utf8");
  renameSync(temporary, target);

  return target;
}

// Derived from the run directory so a restarted driver finds the same socket,
// and short enough to stay inside the platform path limit.
export function socketPathFor(runDir) {
  const hash = createHash("sha256").update(runDir).digest("hex").slice(0, SOCKET_HASH_LENGTH);

  return join(tmpdir(), `ux-qa-${hash}.sock`);
}

// Exit 0 completed the goal, exit 1 did not, and everything else (2, a signal,
// no exit code at all) or a server that is not alive is a harness error.
export function resultStatus(checkExit, serverAlive = true) {
  if (serverAlive === false) return HARNESS_ERROR;
  if (checkExit === 0) return { status: "completed", pass: true };
  if (checkExit === 1) return { status: "not-completed", pass: false };

  return HARNESS_ERROR;
}
