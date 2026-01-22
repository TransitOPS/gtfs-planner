# PR Rules

## Branch & PR Title

- Branch name: `type/scope/ISSUE_NUMBER-short-desc` (e.g., `feat/ui/76-pathway-slider`)
  - **MUST include GitHub issue number** to enable automatic linking and context tracking
  - The issue number helps GitHub, AI assistants, and team members connect branches to issues and PRs
- PR title: Conventional Commit style — `type(scope): summary`

## Focus

- Keep PRs narrowly scoped; if it grows, propose splitting
- Align with any existing repo PR template fields

## Description

- Use `docs/pr-template.md` verbatim unless asked otherwise
- Include screenshots/GIFs for UI; before/after when relevant

## Checklist

- Tests added/updated where it makes sense
- Docs updated (README, comments, user docs)
- CI passes
- No breaking changes (or migration noted clearly)

## Implementation Note

To avoid shell escaping issues and conflicts with bash/zsh when creating PRs, use temporary files for PR descriptions instead of inline flags:

1. **Create a temporary file** for the PR description:

   ```bash
   TEMP_FILE=$(mktemp /tmp/pr-desc-XXXXXX.md)
   echo "# PR Title" > "$TEMP_FILE"
   echo "" >> "$TEMP_FILE"
   echo "Detailed PR description..." >> "$TEMP_FILE"
   echo "## Changes" >> "$TEMP_FILE"
   echo "- Item 1" >> "$TEMP_FILE"
   ```

2. **Create PR using the file** (with GitHub CLI):

   ```bash
   gh pr create --title "type(scope): summary" --body-file "$TEMP_FILE"
   ```

3. **Clean up** the temporary file:

   ```bash
   rm "$TEMP_FILE"
   ```

4. **Prevent accidental commits** of temporary files created *inside the repository* by adding patterns to `.gitignore` (note: files created in `/tmp` are outside the repo and do not need to be ignored):