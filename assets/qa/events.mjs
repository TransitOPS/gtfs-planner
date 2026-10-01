// Buffers browser events for a tester run.
//
// The driver registers page listeners once and pushes every event here; the
// next command drains the buffer, so events that arrive between commands are
// attributed to the step that follows them instead of being lost.
//
// This module is pure: it imports nothing, touches no browser and writes no
// file. It is also the single home of the stub URL prefixes, which the
// driver, `result.json` and the limits slide all read from here.

export const STUB_PATH_PREFIXES = ["/map/tiles/", "/map/buildings"];

// Console levels that count as a product error. Everything else is noise.
const CONSOLE_ERROR_LEVELS = ["error"];

// A response is only an error worth reporting when the page itself failed.
const HTTP_ERROR_RESOURCE_TYPE = "document";

// A failed request matters when it took the page or its data with it; a failed
// font, image or stylesheet is the browser being thorough.
const FAILED_REQUEST_RESOURCE_TYPES = ["document", "xhr", "fetch"];

const FIRST_MESSAGES = 3;

export function isStubUrl(url) {
  if (typeof url !== "string" || url.trim() === "") return false;

  let pathname;

  try {
    pathname = new URL(url).pathname;
  } catch {
    // An unparsable value is not a stub; refusing to guess keeps a real
    // product error from being dropped on the floor.
    return false;
  }

  return STUB_PATH_PREFIXES.some(prefix => pathname.startsWith(prefix));
}

function firstMessages(texts) {
  return texts.slice(0, FIRST_MESSAGES);
}

export class EventBuffer {
  constructor() {
    this.events = [];
  }

  push(event) {
    this.events.push(event);
    return this;
  }

  // The console text of a console or page-error event, and a short description
  // of a network event, so the counts and the first messages in a step record
  // read the same way.
  static textFor(event) {
    switch (event.type) {
      case "console":
      case "pageerror":
        return event.text;
      case "response":
        return `${event.status} ${event.url}`;
      case "requestfailed":
        return `${event.url} (${event.resourceType})`;
      default:
        return event.text ?? event.name ?? event.message ?? "";
    }
  }

  // Console-level errors the page reported, including uncaught page errors.
  // A stub URL is not a product error, so a stub-rendered message is not
  // counted even when the console calls it an error.
  countConsoleError(event) {
    if (event.type === "pageerror") return !isStubUrl(event.url);
    if (event.type !== "console") return false;
    if (!CONSOLE_ERROR_LEVELS.includes(event.level)) return false;

    return !isStubUrl(event.url);
  }

  // Network-level errors: a document that answered with a failing status, or a
  // request for the page or its data that never completed. Stub requests are
  // skipped: they have no upstream by design.
  countHttpError(event) {
    if (isStubUrl(event.url)) return false;

    if (event.type === "response") {
      return event.resourceType === HTTP_ERROR_RESOURCE_TYPE && event.status >= 400;
    }

    if (event.type === "requestfailed") {
      return FAILED_REQUEST_RESOURCE_TYPES.includes(event.resourceType);
    }

    return false;
  }

  // Empty the buffer and report everything it held, so the caller's step
  // record owns exactly the events that happened since the previous drain.
  drain() {
    const consoleErrors = [];
    const httpErrors = [];
    const dialogs = [];
    const downloads = [];

    for (const event of this.events) {
      if (this.countConsoleError(event)) {
        consoleErrors.push(EventBuffer.textFor(event));
      } else if (this.countHttpError(event)) {
        httpErrors.push(EventBuffer.textFor(event));
      } else if (event.type === "dialog") {
        dialogs.push(event.message);
      } else if (event.type === "download") {
        downloads.push(event.name);
      }
    }

    this.events = [];

    return {
      consoleErrors: { count: consoleErrors.length, first: firstMessages(consoleErrors) },
      httpErrors: { count: httpErrors.length, first: firstMessages(httpErrors) },
      dialogs,
      downloads
    };
  }
}
