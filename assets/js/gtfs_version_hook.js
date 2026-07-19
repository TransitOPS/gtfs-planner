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

    const storedVersion = this.safeGetItem(this.storageKey);
    const isGtfsPage = /^\/gtfs\/[^/]+/.test(window.location.pathname);
    if (isGtfsPage) {
      this.pushEvent("gtfs_version_loaded", { version_id: storedVersion });
    }

    this.handleEvent("gtfs_version_selected", ({ version_id }) => {
      if (version_id) {
        this.safeSetItem(this.storageKey, version_id);
      }
    });

    this.pagehideHandler = () => this.onPagehide();
    window.addEventListener("pagehide", this.pagehideHandler);

    this.bindSelect();
    this.bindRetry();
  },

  updated() {
    this.bindSelect();
    this.bindRetry();
  },

  destroyed() {
    this.unbindSelect();
    this.unbindRetry();
    this.clearWatchdog();
    if (this.pagehideHandler) {
      window.removeEventListener("pagehide", this.pagehideHandler);
      this.pagehideHandler = null;
    }
    this.pendingValue = null;
    this.priorValue = null;
    this.failedValue = null;
  },

  bindSelect() {
    const select = this.el.querySelector("select");
    if (this.boundSelect === select) return;
    this.unbindSelect();
    if (!select) return;
    this.boundSelect = select;
    this.lastKnownValue = select.value;
    this.changeHandler = (event) => this.selectVersion(event.target.value);
    select.addEventListener("change", this.changeHandler);
  },

  unbindSelect() {
    if (this.boundSelect && this.changeHandler) {
      this.boundSelect.removeEventListener("change", this.changeHandler);
    }
    this.boundSelect = null;
    this.changeHandler = null;
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

    const select = this.el.querySelector("select");
    if (!select) return;

    this.priorValue = this.lastKnownValue !== undefined ? this.lastKnownValue : select.value;
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

    const select = this.el.querySelector("select");
    if (select && this.priorValue !== null) {
      select.value = this.priorValue;
      this.lastKnownValue = this.priorValue;
    }

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

  setBusy(busy) {
    const select = this.el.querySelector("select");
    if (select) select.disabled = busy;
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
