const GtfsVersionHook = {
  mounted() {
    this.organizationId = this.el.dataset.organizationId;
    this.storageKey = `gtfs_version_${this.organizationId}`;

    const storedVersion = localStorage.getItem(this.storageKey);
    const isGtfsPage = /^\/gtfs\/[^/]+/.test(window.location.pathname);
    if (isGtfsPage) {
      this.pushEvent("gtfs_version_loaded", { version_id: storedVersion });
    }

    this.handleEvent("gtfs_version_selected", ({ version_id }) => {
      if (version_id) {
        localStorage.setItem(this.storageKey, version_id);
      }
    });

    this.bindSelect();
  },

  updated() {
    this.bindSelect();
  },

  destroyed() {
    this.unbindSelect();
  },

  bindSelect() {
    const select = this.el.querySelector("select");
    if (this.boundSelect === select) return;
    this.unbindSelect();
    if (!select) return;
    this.boundSelect = select;
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

  selectVersion(versionId) {
    localStorage.setItem(this.storageKey, versionId);
    const currentPath = window.location.pathname;
    const newPath = currentPath.replace(/\/gtfs\/[^/]+/, `/gtfs/${versionId}`);
    window.location.href = newPath;
  },
};

export default GtfsVersionHook;
