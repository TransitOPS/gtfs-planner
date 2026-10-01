import { expect, test } from "vitest";

import { EventBuffer, STUB_PATH_PREFIXES, isStubUrl } from "../../qa/events.mjs";

test("a basemap tile URL is a stub URL", () => {
  expect(isStubUrl("http://localhost:4002/map/tiles/12/2048/1024.png")).toBe(true);
});

test("a building request URL is a stub URL", () => {
  expect(isStubUrl("http://localhost:4002/map/buildings?lat=1&lon=2")).toBe(true);
});

test("a product URL is not a stub URL", () => {
  expect(isStubUrl("http://localhost:4002/gtfs/import")).toBe(false);
});

test("a stub path outside the prefix list is not a stub URL", () => {
  expect(isStubUrl("http://localhost:4002/map/tiles")).toBe(false);
});

test("an unparsable value is not a stub URL", () => {
  expect(isStubUrl("not a url")).toBe(false);
});

test("the stub prefixes are the two published paths", () => {
  expect(STUB_PATH_PREFIXES).toEqual(["/map/tiles/", "/map/buildings"]);
});

test("a console error from a stub URL is not counted", () => {
  const buffer = new EventBuffer();

  buffer.push({
    type: "console",
    level: "error",
    text: "tile load failed",
    url: "http://localhost:4002/map/tiles/12/2048/1024.png"
  });

  expect(buffer.drain().consoleErrors).toEqual({ count: 0, first: [] });
});

test("a console warning is not counted but a console error is", () => {
  const buffer = new EventBuffer();

  buffer.push({
    type: "console",
    level: "warning",
    text: "slow response",
    url: "http://localhost:4002/gtfs/import"
  });
  buffer.push({
    type: "console",
    level: "error",
    text: "boom",
    url: "http://localhost:4002/gtfs/import"
  });

  expect(buffer.drain().consoleErrors).toEqual({ count: 1, first: ["boom"] });
});

test("an uncaught page error is counted as a console error", () => {
  const buffer = new EventBuffer();

  buffer.push({ type: "pageerror", text: "TypeError: undefined is not a function" });

  expect(buffer.drain().consoleErrors).toEqual({
    count: 1,
    first: ["TypeError: undefined is not a function"]
  });
});

test("events pushed before any drain appear in the next drain", () => {
  const buffer = new EventBuffer();

  buffer.push({
    type: "console",
    level: "error",
    text: "between commands",
    url: "http://localhost:4002/gtfs/import"
  });
  buffer.push({ type: "dialog", message: "Leave this page?" });
  buffer.push({ type: "download", name: "sample-feed.zip" });

  const first = buffer.drain();

  expect(first.consoleErrors.count).toBe(1);
  expect(first.dialogs).toEqual(["Leave this page?"]);
  expect(first.downloads).toEqual(["sample-feed.zip"]);
});

test("a second drain is empty", () => {
  const buffer = new EventBuffer();

  buffer.push({
    type: "console",
    level: "error",
    text: "boom",
    url: "http://localhost:4002/gtfs/import"
  });
  buffer.drain();

  expect(buffer.drain()).toEqual({
    consoleErrors: { count: 0, first: [] },
    httpErrors: { count: 0, first: [] },
    dialogs: [],
    downloads: []
  });
});

test("only the first three messages are reported", () => {
  const buffer = new EventBuffer();

  for (const text of ["one", "two", "three", "four", "five"]) {
    buffer.push({
      type: "console",
      level: "error",
      text,
      url: "http://localhost:4002/gtfs/import"
    });
  }

  const drained = buffer.drain();

  expect(drained.consoleErrors.count).toBe(5);
  expect(drained.consoleErrors.first).toEqual(["one", "two", "three"]);
});

test("a 404 document response counts and a 404 image response does not", () => {
  const buffer = new EventBuffer();

  buffer.push({
    type: "response",
    url: "http://localhost:4002/gtfs/v1/stations",
    status: 404,
    resourceType: "document"
  });
  buffer.push({
    type: "response",
    url: "http://localhost:4002/assets/logo.png",
    status: 404,
    resourceType: "image"
  });

  const drained = buffer.drain();

  expect(drained.httpErrors.count).toBe(1);
  expect(drained.httpErrors.first).toEqual(["404 http://localhost:4002/gtfs/v1/stations"]);
});

test("a 200 document response is not an error", () => {
  const buffer = new EventBuffer();

  buffer.push({
    type: "response",
    url: "http://localhost:4002/gtfs/import",
    status: 200,
    resourceType: "document"
  });

  expect(buffer.drain().httpErrors.count).toBe(0);
});

test("a failed fetch counts and a failed stylesheet does not", () => {
  const buffer = new EventBuffer();

  buffer.push({
    type: "requestfailed",
    url: "http://localhost:4002/live/websocket",
    resourceType: "xhr"
  });
  buffer.push({
    type: "requestfailed",
    url: "http://localhost:4002/assets/app.css",
    resourceType: "stylesheet"
  });

  const drained = buffer.drain();

  expect(drained.httpErrors.count).toBe(1);
  expect(drained.httpErrors.first).toEqual([
    "http://localhost:4002/live/websocket (xhr)"
  ]);
});

test("a failed stub request is not an error", () => {
  const buffer = new EventBuffer();

  buffer.push({
    type: "requestfailed",
    url: "http://localhost:4002/map/tiles/12/2048/1024.png",
    resourceType: "document"
  });

  expect(buffer.drain().httpErrors.count).toBe(0);
});
