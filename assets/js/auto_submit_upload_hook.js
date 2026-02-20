/**
 * AutoSubmitUpload Hook
 * Automatically submits a form when a file is selected in a file input.
 */
const POLL_INTERVAL_MS = 100;
const MAX_NO_REF_POLLS = 3;
const UPLOAD_TIMEOUT_MS = 60_000;

const AutoSubmitUploadHook = {
  mounted() {
    this.form = this.el;
    this.fileInput = this.form.querySelector('input[type="file"]');
    this.pollTimer = null;
    this.timeoutTimer = null;
    this.sawUploadActivity = false;
    this.noRefPollCount = 0;

    if (!this.fileInput) return;

    this.onChange = () => this.startUploadWait();
    this.fileInput.addEventListener("change", this.onChange);
  },

  destroyed() {
    this.clearUploadWait();

    if (this.fileInput && this.onChange) {
      this.fileInput.removeEventListener("change", this.onChange);
    }
  },

  startUploadWait() {
    if (!this.fileInput || this.fileInput.files.length === 0) return;

    this.clearUploadWait();
    this.sawUploadActivity = false;
    this.noRefPollCount = 0;

    this.pollTimer = window.setInterval(() => {
      if (this.shouldSubmit()) {
        this.form.dispatchEvent(new Event("submit", { bubbles: true, cancelable: true }));
        this.clearUploadWait();
      } else if (this.shouldStopWithoutUpload()) {
        this.clearUploadWait();
      }
    }, POLL_INTERVAL_MS);

    this.timeoutTimer = window.setTimeout(() => {
      this.clearUploadWait();
      this.pushEvent("set_diagram_error", { reason: "timeout" });
    }, UPLOAD_TIMEOUT_MS);
  },

  shouldSubmit() {
    const activeRefs = this.readRefs("data-phx-active-refs");
    const preflightedRefs = this.readRefs("data-phx-preflighted-refs");
    const doneRefs = this.readRefs("data-phx-done-refs");

    if (activeRefs.size > 0) {
      this.sawUploadActivity = true;
      return false;
    }

    if (this.sawUploadActivity) {
      return true;
    }

    if (preflightedRefs.size === 0) {
      return false;
    }

    for (const ref of preflightedRefs) {
      if (!doneRefs.has(ref)) {
        return false;
      }
    }

    return true;
  },

  shouldStopWithoutUpload() {
    if (this.sawUploadActivity) return false;

    const hasAnyRefs =
      this.readRefs("data-phx-active-refs").size > 0 ||
      this.readRefs("data-phx-preflighted-refs").size > 0 ||
      this.readRefs("data-phx-done-refs").size > 0;

    if (hasAnyRefs) {
      this.noRefPollCount = 0;
      return false;
    }

    this.noRefPollCount += 1;
    return this.noRefPollCount >= MAX_NO_REF_POLLS;
  },

  readRefs(attribute) {
    if (!this.fileInput) return new Set();

    const refs = this.fileInput.getAttribute(attribute);
    if (!refs) return new Set();

    return new Set(
      refs
        .split(",")
        .map((ref) => ref.trim())
        .filter((ref) => ref.length > 0)
    );
  },

  clearUploadWait() {
    if (this.pollTimer) {
      window.clearInterval(this.pollTimer);
      this.pollTimer = null;
    }

    if (this.timeoutTimer) {
      window.clearTimeout(this.timeoutTimer);
      this.timeoutTimer = null;
    }

    this.noRefPollCount = 0;
  }
};

export default AutoSubmitUploadHook;
