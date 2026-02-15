/**
 * GtfsVersionHook - Manages GTFS version selection persistence via localStorage.
 */
const GtfsVersionHook = {
  mounted() {
    const organizationId = this.el.dataset.organizationId;
    const storageKey = `gtfs_version_${organizationId}`;
    
    // Read stored version from localStorage
    const storedVersion = localStorage.getItem(storageKey);
    
    // Only GTFS pages handle this event; avoid crashing non-GTFS LiveViews.
    const isGtfsPage = /^\/gtfs\/[^/]+/.test(window.location.pathname);
    if (isGtfsPage) {
      this.pushEvent("gtfs_version_loaded", { version_id: storedVersion });
    }
    
    // Handle select change directly in JS to avoid race condition with LiveView re-render
    const select = this.el.querySelector('select');
    if (select) {
      // Store handler reference for cleanup
      this.changeHandler = (e) => {
        const versionId = e.target.value;
        
        // Update localStorage immediately
        localStorage.setItem(storageKey, versionId);
        
        // Navigate to new version URL (replace version segment in current path)
        const currentPath = window.location.pathname;
        const newPath = currentPath.replace(/\/gtfs\/[^\/]+/, `/gtfs/${versionId}`);
        window.location.href = newPath;
      };
      select.addEventListener('change', this.changeHandler);
    }
    
    // Handle version selection events from server
    this.handleEvent("gtfs_version_selected", ({ version_id }) => {
      if (version_id) {
        localStorage.setItem(storageKey, version_id);
      }
    });
  },
  
  destroyed() {
    const select = this.el.querySelector('select');
    if (select && this.changeHandler) {
      select.removeEventListener('change', this.changeHandler);
    }
  }
};

export default GtfsVersionHook;
