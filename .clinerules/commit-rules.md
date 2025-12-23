# Conventional Commit Rules

## Allowed types

feat, fix, docs, style, refactor, perf, test, build, ci, chore, revert

## Format

`type(scope)!: short, imperative summary`

- **scope**: kebab-case area (see `scopes.md`)
- **summary**: ≤ 50 chars, imperative, no trailing period
- **breaking**: add `!` after type or scope and include a
  **BREAKING CHANGE** footer describing impact & migration

## Body (recommended)

- Wrap ~72 chars per line
- Explain **why** the change was needed
- Call out tradeoffs, alternatives, perf/security notes

## Implementation Note

To avoid shell escaping issues and conflicts with bash/zsh when writing commit messages, use temporary files instead of inline `-m` flags:

1. **Create a temporary file** for the commit message:

   ```bash
   TEMP_FILE=$(mktemp /tmp/commit-msg-XXXXXX.txt)
   echo "type(scope): short, imperative summary" > "$TEMP_FILE"
   echo "" >> "$TEMP_FILE"
   echo "Body explaining why the change was needed..." >> "$TEMP_FILE"
   ```

2. **Commit using the file**:

   ```bash
   git commit -F "$TEMP_FILE"
   ```

3. **Clean up** the temporary file:

   ```bash
   rm "$TEMP_FILE"
   ```

4. **Prevent accidental commits** of temporary files by adding patterns to `.gitignore`:
   ```
   /tmp/commit-msg-*.txt
   *.tmp
   ```

This approach handles multi-line messages, special characters, and avoids shell interpretation problems. The temporary file should be deleted immediately after the commit and never committed to the repository.
