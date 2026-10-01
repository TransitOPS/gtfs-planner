// Where a capture lives and what a capture ID means (rule R4, contracts C-7
// and C-9).
//
// A capture is identified by its path: `JRNY-001/import-s003` is
// `<root>/journeys/JRNY-001/import-s003.png` and `SCRN-001/empty` is
// `<root>/screens/SCRN-001/empty.png`. There is no manifest, so a missing file
// simply reads as "not captured" and none of these functions touch the disk
// except the one `git check-ignore` call that stops a writer before it writes
// into a folder the repository would commit.
//
// The root, the path rule, the ID parse, the pruning selection and the ignore
// check live here so the driver, the replay client and the review tooling
// cannot disagree about any of them.

import { execFileSync } from "node:child_process";
import { join } from "node:path";

// The owner prefix picks the folder: `SCRN-` holds screens, `JRNY-` holds
// journey scenarios.
const OWNER_FOLDERS = { SCRN: "screens", JRNY: "journeys" };

// `SCRN-###/name` and `JRNY-###/name`, the name being the file name without
// its extension.
const CAPTURE_ID_PATTERN = /^(SCRN|JRNY)-(\d{3})\/([a-z0-9][a-z0-9-]*)$/;

const CAPTURE_EXTENSION = ".png";

const STEP_DIGITS = 3;

// `<primary>/.specs/images`, the default root. A repository that already
// commits its captures declares another root, and the layout below is
// unchanged under it.
export function captureRoot(primary) {
  return join(primary, ".specs", "images");
}

// `<root>/journeys/JRNY-001/import-s003.png` for step 3 of `JRNY-001/import`.
// The number is the trail step index, zero-padded to three, so a re-capture of
// the same step overwrites in place and a shorter trail can be pruned by
// number.
export function journeyCapturePath(root, scenarioId, n) {
  const [owner, slug] = matchScenarioId(scenarioId);
  const step = String(n).padStart(STEP_DIGITS, "0");

  return join(root, OWNER_FOLDERS.JRNY, owner, `${slug}-s${step}${CAPTURE_EXTENSION}`);
}

// `JRNY-001/import-s003` becomes `{ owner, name, path }`. The path is a
// location, not a claim that a file exists: the caller's own presence check
// decides whether the capture was taken.
export function parseCaptureId(id, root) {
  const [owner, folder, name] = matchCaptureId(id);

  return { owner, name, path: join(root, folder, owner, `${name}${CAPTURE_EXTENSION}`) };
}

// The capture files a shorter trail leaves behind: this scenario's own
// `<slug>-s<NNN>` files whose step number is above the new count. Another
// scenario's files in the same journey folder are never selected, and neither
// is a step the trail still has.
export function staleCaptureFiles(fileNames, slug, keepCount) {
  const pattern = new RegExp(
    `^${escapePattern(slug)}-s(\\d{${STEP_DIGITS}})(?:-.*)?${CAPTURE_EXTENSION}$`
  );

  return fileNames.filter((fileName) => {
    const match = pattern.exec(fileName);

    return match !== null && Number(match[1]) > keepCount;
  });
}

// Stops a writer before its first capture when the root is not ignored, which
// is the only way a capture could reach a commit. The predicate is injectable
// so the rule is testable without a git process.
export function assertRootIgnored(root, isIgnored = defaultCheck) {
  if (isIgnored(root)) return root;

  throw new Error(`the capture root is not git-ignored, so a capture would be committed: ${root}`);
}

// `git check-ignore -q <root>` in the repository that owns the root. The
// command only applies that repository's ignore rules when it runs inside it,
// and the default root sits two levels below the primary checkout, which is
// therefore the default working directory. A repository that declares another
// root passes its own checkout instead. A git failure is a false predicate: a
// root that cannot be proven ignored is not ignored.
export function defaultCheck(root, cwd = join(root, "..", "..")) {
  try {
    execFileSync("git", ["check-ignore", "-q", root], { cwd, stdio: "ignore" });

    return true;
  } catch {
    return false;
  }
}

// The scenario ID is a capture ID whose owner is a journey; the same pattern
// validates both so a scenario cannot drift from a capture ID.
function matchScenarioId(scenarioId) {
  const [owner, folder, slug] = matchCaptureId(scenarioId);

  if (folder !== OWNER_FOLDERS.JRNY) {
    throw new Error(`not a journey scenario ID: ${scenarioId} (expected JRNY-###/<slug>)`);
  }

  return [owner, slug];
}

function matchCaptureId(id) {
  const match = CAPTURE_ID_PATTERN.exec(id);

  if (!match) {
    throw new Error(`not a capture ID: ${id} (expected SCRN-###/name or JRNY-###/name)`);
  }

  const [, prefix, number, name] = match;

  return [`${prefix}-${number}`, OWNER_FOLDERS[prefix], name];
}

function escapePattern(text) {
  return text.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}
