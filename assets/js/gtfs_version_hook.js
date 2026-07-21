const WATCHDOG_MS = 5000;

const GtfsVersionHook = {
  mounted() {
    this.organizationId = this.el.dataset.organizationId;
    this.storageKey = `gtfs_version_${this.organizationId}`;
    this.priorValue = null;
    this.pendingValue = null;
    this.failedValue = null;
    this.watchdogTimer = null;
    this.navigated = false;

    const currentVersion = this.currentVersion();
    if (currentVersion) {
      this.safeSetItem(this.storageKey, currentVersion);
    }

    this.handleEvent("gtfs_version_selected", ({ version_id }) => {
      if (version_id) {
        this.safeSetItem(this.storageKey, version_id);
      }
    });

    this.pagehideHandler = () => this.onPagehide();
    window.addEventListener("pagehide", this.pagehideHandler);

    this.pageshowHandler = () => this.onPageshow();
    window.addEventListener("pageshow", this.pageshowHandler);

    this.bindOptions();
    this.bindRetry();
  },

  updated() {
    this.bindOptions();
    this.bindRetry();
  },

  destroyed() {
    this.unbindOptions();
    this.unbindRetry();
    this.clearWatchdog();
    if (this.pagehideHandler) {
      window.removeEventListener("pagehide", this.pagehideHandler);
      this.pagehideHandler = null;
    }
    if (this.pageshowHandler) {
      window.removeEventListener("pageshow", this.pageshowHandler);
      this.pageshowHandler = null;
    }
    this.pendingValue = null;
    this.priorValue = null;
    this.failedValue = null;
  },

  bindOptions() {
    const options = Array.from(this.el.querySelectorAll("[data-version-option]"));
    if (this.sameOptions(options)) return;
    this.unbindOptions();
    if (options.length === 0) return;
    this.optionHandlers = new Map();
    options.forEach((btn) => {
      const handler = () => this.selectVersion(btn.dataset.versionId);
      btn.addEventListener("click", handler);
      this.optionHandlers.set(btn, handler);
    });
    this.boundOptions = options;
  },

  sameOptions(options) {
    if (!this.boundOptions || this.boundOptions.length !== options.length) return false;
    return this.boundOptions.every((btn, i) => btn === options[i]);
  },

  unbindOptions() {
    if (this.optionHandlers) {
      this.optionHandlers.forEach((handler, btn) =>
        btn.removeEventListener("click", handler),
      );
    }
    this.optionHandlers = null;
    this.boundOptions = null;
  },

  currentVersion() {
    return this.el.dataset.currentVersion;
  },

  bindRetry() {
    const btn = this.el.querySelector("#gtfs-version-retry");
    if (this.boundRetry === btn) return;
    this.unbindRetry();
    if (!btn) return;
    this.boundRetry = btn;
    this.retryHandler = () => this.retryNavigation();
    btn.addEventListener("click", this.retryHandler);
  },

  unbindRetry() {
    if (this.boundRetry && this.retryHandler) {
      this.boundRetry.removeEventListener("click", this.retryHandler);
    }
    this.boundRetry = null;
    this.retryHandler = null;
  },

  selectVersion(versionId) {
    if (this.pendingValue !== null) return;
    if (!versionId || versionId === this.currentVersion()) return;

    this.priorValue = this.currentVersion();
    this.pendingValue = versionId;

    this.setBusy(true);
    this.showPending(true);
    this.showFailure(false);

    this.safeSetItem(this.storageKey, versionId);
    this.navigate(versionId);
  },

  navigate(versionId) {
    let targetUrl;
    try {
      targetUrl = this.buildTargetUrl(versionId);
    } catch (_e) {
      this.recoverFromFailure(versionId);
      return;
    }

    this.startWatchdog();

    try {
      window.location.href = targetUrl;
    } catch (_e) {
      this.recoverFromFailure(versionId);
    }
  },

  buildTargetUrl(versionId) {
    const { pathname, search, hash } = window.location;
    const gtfsMatch = pathname.match(/^\/gtfs\/[^/]+/);

    if (gtfsMatch) {
      const newPath = pathname.replace(/^\/gtfs\/[^/]+/, `/gtfs/${versionId}`);
      return newPath + (search || "") + (hash || "");
    }

    return `/gtfs/${versionId}/routes`;
  },

  startWatchdog() {
    this.clearWatchdog();
    this.watchdogTimer = setTimeout(() => {
      this.watchdogTimer = null;
      if (!this.navigated) {
        this.recoverFromFailure(this.pendingValue);
      }
    }, WATCHDOG_MS);
  },

  clearWatchdog() {
    if (this.watchdogTimer !== null) {
      clearTimeout(this.watchdogTimer);
      this.watchdogTimer = null;
    }
  },

  recoverFromFailure(versionId) {
    this.clearWatchdog();
    this.failedValue = versionId;
    this.pendingValue = null;

    // No DOM value to restore: navigation never happened, so the trigger still
    // shows the current version. Just re-enable the control and surface failure.
    this.setBusy(false);
    this.showPending(false);
    this.showFailure(true);
  },

  retryNavigation() {
    const versionId = this.failedValue;
    if (versionId === null) return;

    this.failedValue = null;
    this.pendingValue = versionId;

    this.setBusy(true);
    this.showPending(true);
    this.showFailure(false);

    this.safeSetItem(this.storageKey, versionId);
    this.navigate(versionId);
  },

  onPagehide() {
    this.navigated = true;
    this.clearWatchdog();
  },

  onPageshow() {
    // pagehide fires on tab switch as well as navigation, leaving `navigated`
    // stuck true. Reset it when the page becomes visible again so the watchdog
    // and recovery paths stay live. If a selection is still pending (navigation
    // never happened), surface the failure so the user can retry.
    this.navigated = false;
    if (this.pendingValue !== null) {
      this.recoverFromFailure(this.pendingValue);
    }
  },

  setBusy(busy) {
    const trigger = this.el.querySelector("#gtfs-version-trigger");
    if (trigger) trigger.disabled = busy;
    this.el.querySelectorAll("[data-version-option]").forEach((btn) => {
      btn.disabled = busy;
    });
  },

  showPending(visible) {
    const pending = this.el.querySelector("#gtfs-version-pending");
    if (pending) {
      pending.hidden = !visible;
      if (visible) pending.textContent = "Switching version\u2026";
    }
  },

  showFailure(visible) {
    const failure = this.el.querySelector("#gtfs-version-failure");
    if (failure) failure.hidden = !visible;
  },

  safeGetItem(key) {
    try {
      return localStorage.getItem(key);
    } catch (_e) {
      return null;
    }
  },

  safeSetItem(key, value) {
    try {
      localStorage.setItem(key, value);
    } catch (_e) {
      // storage failure is degraded convenience, not navigation failure
    }
  },
};

export default GtfsVersionHook;
