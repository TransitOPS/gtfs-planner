import zlib from "node:zlib";

export const VIEWPORTS = [
  { label: "320px", width: 320, height: 568 },
  { label: "768px", width: 768, height: 1024 },
  { label: "desktop", width: 1280, height: 800 },
  // 200% browser zoom of a 1280x800 device viewport is a 640x400 CSS layout
  // viewport. Exercising the layout viewport directly runs the media queries.
  { label: "640px (200% zoom)", width: 640, height: 400 },
];

/**
 * Records every mutation of a control from the moment before it is activated.
 *
 * `phx-disable-with` swaps the label and disables the control synchronously,
 * before the event is pushed, so polling assertions can miss it on a fast local
 * server. A MutationObserver captures the transition without a race.
 */
export async function watchPendingState(page, selector) {
  await page.evaluate((sel) => {
    const el = document.querySelector(sel);
    if (!el) throw new Error(`No element for ${sel}`);
    window.__pendingStates = [];
    window.__pendingObserver = new MutationObserver(() => {
      window.__pendingStates.push({
        disabled: el.hasAttribute("disabled"),
        text: el.textContent.trim(),
      });
    });
    window.__pendingObserver.observe(el, {
      attributes: true,
      childList: true,
      subtree: true,
      characterData: true,
    });
  }, selector);
}

export async function readPendingStates(page) {
  return page.evaluate(() => {
    window.__pendingObserver?.disconnect();
    return window.__pendingStates ?? [];
  });
}

export async function bodyFitsViewport(page) {
  return page.evaluate(
    () => document.body.scrollWidth <= window.innerWidth,
  );
}

/**
 * Reads one text member out of a ZIP archive without adding a runtime
 * dependency: the central directory is walked to find the entry, and its
 * bytes are inflated with Node's zlib when the entry is deflated.
 */
export function readZipTextMember(buffer, memberName) {
  const view = new DataView(buffer.buffer, buffer.byteOffset, buffer.byteLength);
  const decode = new TextDecoder("utf-8");

  let offset = 0;
  while (offset + 30 <= view.byteLength) {
    if (view.getUint32(offset, true) !== 0x04034b50) break;

    const method = view.getUint16(offset + 8, true);
    const compressedSize = view.getUint32(offset + 18, true);
    const nameLength = view.getUint16(offset + 26, true);
    const extraLength = view.getUint16(offset + 28, true);
    const nameStart = offset + 30;
    const name = decode.decode(
      new Uint8Array(buffer.buffer, buffer.byteOffset + nameStart, nameLength),
    );
    const dataStart = nameStart + nameLength + extraLength;
    const dataEnd = dataStart + compressedSize;

    if (name === memberName) {
      const compressed = buffer.subarray(dataStart, dataEnd);

      if (method === 0) return decode.decode(compressed);
      if (method === 8) {
        return zlib.inflateRawSync(compressed).toString("utf8");
      }

      throw new Error(`Unsupported ZIP compression method ${method}`);
    }

    offset = dataEnd;
  }

  throw new Error(`${memberName} is not present in the archive`);
}
