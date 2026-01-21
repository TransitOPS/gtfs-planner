/**
 * GtfsVersionHook - Manages GTFS version selection persistence via localStorage
 * 
 * This hook:
 * 1. Reads the last-selected GTFS version from localStorage on mount
 * 2. Pushes the stored version to the server for validation
 * 3. Handles server events to update localStorage when version changes
 * 4. Handles redirect events from the server
 */
const GtfsVersionHook = {
  mounted() {
    const organizationId = this.el.dataset.organizationId;
    const storageKey = `gtfs_version_${organizationId}`;
    
    // Read stored version from localStorage
    const storedVersion = localStorage.getItem(storageKey);
    
    // Push the stored version to the server for validation
    this.pushEvent("gtfs_version_loaded", { version_id: storedVersion });
    
    // Handle version selection events from server
    this.handleEvent("gtfs_version_selected", ({ version_id }) => {
      if (version_id) {
        localStorage.setItem(storageKey, version_id);
      }
    });
    
    // Handle redirect events from server
    this.handleEvent("gtfs_version_redirect", ({ url }) => {
      if (url) {
        window.location.href = url;
      }
    });
  }
};

export default GtfsVersionHook;