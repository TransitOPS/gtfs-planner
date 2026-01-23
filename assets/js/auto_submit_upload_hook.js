/**
 * AutoSubmitUpload Hook
 * Automatically submits a form when a file is selected in a file input.
 */
const AutoSubmitUploadHook = {
  mounted() {
    const form = this.el;
    const fileInput = form.querySelector('input[type="file"]');
    if (fileInput) {
      fileInput.addEventListener("change", () => {
        // Small delay to ensure LiveView has processed the file
        setTimeout(() => {
          form.dispatchEvent(new Event("submit", { bubbles: true, cancelable: true }));
        }, 100);
      });
    }
  }
};

export default AutoSubmitUploadHook;