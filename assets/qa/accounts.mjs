// Test-only credentials for a tester (person or script), mirrored in
// test/support/ux_qa_seed.exs. The seed creates this editor against a
// throwaway QA database, so these values are never real account credentials.

export const ACCOUNTS = {
  editor: {
    email: "qa-editor@gtfs-planner.test",
    password: "QaEditor12345!"
  }
};