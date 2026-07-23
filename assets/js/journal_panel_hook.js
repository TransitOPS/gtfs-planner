const TOP_THRESHOLD_PX = 8;
const SCROLL_DEBOUNCE_MS = 50;

/**
 * Browser-only adapter for the station journal panel.
 *
 * LiveView owns every journal state transition. This hook reports the current
 * scroll threshold and performs focus/scroll effects against the latest
 * patched DOM.
 */
const JournalPanelHook = {
  mounted() {
    this.boundList = null;
    this.scrollHandler = null;
    this.scrollTimer = null;
    this.scrollTopTimer = null;
    this.focusTimer = null;
    this.lastAtTop = null;
    this.serverEventRefs = [];

    this.registerServerEvents();
    this.bindList();
  },

  updated() {
    this.bindList();
  },

  destroyed() {
    this.unbindList();
    this.clearScrollTimer();
    this.clearScrollTopTimer();
    this.clearFocusTimer();
    this.removeServerEvents();
    this.lastAtTop = null;
  },

  registerServerEvents() {
    this.serverEventRefs = [
      this.handleEvent("journal-focus", ({ selector } = {}) => {
        if (typeof selector !== "string" || selector.length === 0) return;
        this.scheduleFocus(selector);
      }),
      this.handleEvent("journal-scroll-top", () => this.scheduleScrollTop()),
    ].filter((ref) => ref !== undefined && ref !== null);
  },

  removeServerEvents() {
    if (typeof this.removeHandleEvent === "function") {
      this.serverEventRefs?.forEach((ref) => this.removeHandleEvent(ref));
    }
    this.serverEventRefs = [];
  },

  bindList() {
    const list = this.el.querySelector("#journal-entry-list");
    if (list === this.boundList) return;

    this.unbindList();
    if (!list) return;

    this.boundList = list;
    this.scrollHandler = () => this.scheduleScrollSample();
    list.addEventListener("scroll", this.scrollHandler, { passive: true });
    this.reportScrollFact(this.atTop(list));
  },

  unbindList() {
    if (this.boundList && this.scrollHandler) {
      this.boundList.removeEventListener("scroll", this.scrollHandler);
    }
    this.boundList = null;
    this.scrollHandler = null;
    this.clearScrollTimer();
  },

  atTop(list) {
    return list.scrollTop <= TOP_THRESHOLD_PX;
  },

  scheduleScrollSample() {
    this.clearScrollTimer();
    this.scrollTimer = setTimeout(() => {
      this.scrollTimer = null;
      const currentList = this.el.querySelector("#journal-entry-list");
      if (currentList !== this.boundList) this.bindList();
      if (this.boundList) this.reportScrollFact(this.atTop(this.boundList));
    }, SCROLL_DEBOUNCE_MS);
  },

  clearScrollTimer() {
    if (this.scrollTimer !== null) {
      clearTimeout(this.scrollTimer);
      this.scrollTimer = null;
    }
  },

  reportScrollFact(atTop) {
    if (this.lastAtTop === null) {
      this.lastAtTop = atTop;
      return;
    }
    if (atTop === this.lastAtTop) return;

    this.lastAtTop = atTop;
    this.pushEvent("journal_scroll_state", { at_top: atTop });
  },

  scheduleFocus(selector) {
    this.clearFocusTimer();
    this.focusTimer = setTimeout(() => {
      this.focusTimer = null;
      let target = null;

      try {
        target = this.el.querySelector(selector);
      } catch (_error) {
        return;
      }

      if (typeof target?.focus === "function") target.focus();
    }, 0);
  },

  clearFocusTimer() {
    if (this.focusTimer !== null) {
      clearTimeout(this.focusTimer);
      this.focusTimer = null;
    }
  },

  scheduleScrollTop() {
    this.clearScrollTopTimer();
    this.scrollTopTimer = setTimeout(() => {
      this.scrollTopTimer = null;
      this.bindList();
      const list = this.boundList;
      if (!list) return;

      const behavior = this.reducedMotion() ? "auto" : "smooth";
      try {
        if (typeof list.scrollTo === "function") {
          list.scrollTo({ top: 0, behavior });
        } else {
          list.scrollTop = 0;
        }
      } catch (_error) {
        list.scrollTop = 0;
      }

      this.scheduleScrollSample();
    }, 0);
  },

  clearScrollTopTimer() {
    if (this.scrollTopTimer !== null) {
      clearTimeout(this.scrollTopTimer);
      this.scrollTopTimer = null;
    }
  },

  reducedMotion() {
    try {
      return (
        window.matchMedia?.("(prefers-reduced-motion: reduce)").matches === true
      );
    } catch (_error) {
      return false;
    }
  },
};

export default JournalPanelHook;
