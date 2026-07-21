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
