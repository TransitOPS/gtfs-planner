# Refine Upload Implementation Specification

## Qualifications
*   **Language**: Elixir
*   **Framework**: Phoenix, Plug
*   **Domain**: Configuration Management, Security (Path Traversal Prevention)
*   **Testing**: ExUnit

## Problem Statement
The current implementation of file uploads (`fix/upload/275-display-external-env`) introduces implicit configuration dependencies in the test environment, leading to potential state leakage and violations of the "Explicit over implicit" engineering standard. Furthermore, `GtfsPlannerWeb.UploadsPlug` lacks robust path traversal protection, relying on default behavior which may be insufficient for all deployment scenarios. Finally, the development configuration is implicit, reducing visibility for new developers.

## Goal
Refine the file upload architecture to ensure strict environment isolation, robust security against path traversal, and explicit configuration across all environments.

## Architecture
*   **Configuration**:
    *   `config/runtime.exs`: strict logic to avoid overriding test-specific configurations.
    *   `config/test.exs`: explicitly defines `:uploads_path` using a temporary directory.
    *   `config/dev.exs`: explicitly defines `:uploads_path` to local `priv/uploads`.
*   **Security (Plug)**:
    *   `GtfsPlannerWeb.UploadsPlug`: enforces that the resolved file path strictly resides within the configured `uploads_base` directory using `Path.expand/1` and prefix matching. Returns `403 Forbidden` for traversal attempts.

## Acceptance Criteria
1.  **Test Isolation**: Running tests does not create or modify files in `priv/uploads`. `config/test.exs` uses a system temp directory.
2.  **Explicit Configuration**: `config/dev.exs` and `config/test.exs` clearly state their `:uploads_path`.
3.  **Security**: `GtfsPlannerWeb.UploadsPlug` returns `403 Forbidden` if a request attempts to access a file outside the configured upload directory (e.g., `../config/runtime.exs`).
4.  **Standards Compliance**: Adheres to "Explicit over implicit" and "Build for today" from `@docs/engineering-standards.md`.

## Notes
*   Refer to `docs/engineering-standards.md` for principles on "Explicit over implicit".
*   `Path.expand/1` should be used to resolve both the base path and the requested path before comparison.

## Implementation Steps

1.  **Modify `config/runtime.exs`**
    *   Locate the `config :gtfs_planner, :uploads_path, ...` block.
    *   Wrap this configuration in a conditional check `if config_env() != :test do ... end` to prevent `runtime.exs` from overriding the test environment configuration.

2.  **Modify `config/test.exs`**
    *   Add an explicit configuration line for `:uploads_path`.
    *   Set the value to a temporary directory using `Path.join(System.tmp_dir!(), "gtfs_planner_test_uploads")` to ensure test isolation.

3.  **Modify `config/dev.exs`**
    *   Add an explicit configuration line for `:uploads_path`.
    *   Set the value to `Path.join(:code.priv_dir(:gtfs_planner), "uploads")` to match the default but make it explicit for developers.

4.  **Update `lib/gtfs_planner_web/plugs/uploads_plug.ex`**
    *   Change `Application.get_env` to `Application.fetch_env!` for `:uploads_path` to fail fast if configuration is missing.
    *   Implement path traversal protection:
        *   Resolve the absolute path of the configured `:uploads_path` using `Path.expand/1`.
        *   Construct the requested file path and resolve its absolute path using `Path.expand/1`.
        *   Verify that the resolved file path starts with the resolved uploads path.
    *   If the path is unsafe (traversal attempt), halt the connection with a `403 Forbidden` status and a text body "Forbidden".
    *   Ensure the existing logic (checking `File.regular?`) remains for valid paths.
    *   Ensure requests for non-existent files (valid path but no file) pass through to the next plug (return `conn`).

5.  **Update `test/gtfs_planner_web/plugs/uploads_plug_test.exs`**
    *   Add a new test case: "returns 403 for path traversal attempts".
    *   In the test, simulate a request with `path_info` containing `..` (e.g., `["uploads", "..", "mix.exs"]`).
    *   Assert that the response has a `403` status and the body contains "Forbidden".
