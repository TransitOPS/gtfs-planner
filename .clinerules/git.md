# Git Rules

- **Branch naming with issue numbers**

  - Branch name format: `type/scope/ISSUE_NUMBER-short-desc` (e.g., `feat/gtfs/76-route-to-single-stop-page`)
  - **MUST include GitHub issue number** to enable automatic linking and context tracking
  - The issue number helps GitHub, AI assistants, and team members connect branches to issues and PRs
  - When references are made to "the current GitHub issue", deduce it from the current branch name

- **Conventional commits only**

  - All commit messages MUST follow the Conventional Commit style for the subject line.
  - Do NOT explain or redefine the format in this repository; assume it is already known.

- **Commit messages MUST come from a temp file (assistant-managed)**

  - Never use `git commit -m "..."` or any inline commit message on the CLI.
  - The assistant MUST write the full commit message to a temp file (created/updated by the assistant, not via shell redirection or here-docs).
  - Run commits using:
    - `git commit -F <path-to-temp-file>`

- **Shell-safe git commands (bash/zsh compatible)**
  - Do NOT embed free-form text (commit messages, descriptions, etc.) directly in `git` commands.
  - Do NOT use shell features that require tricky quoting or special characters (no here-docs, command substitution, or inline redirection in git commands).
  - When writing `git` commands, restrict arguments to safe characters: letters, numbers, `_`, `-`, `.`, `/`, and spaces.
    - Avoid characters that can conflict with bash/zsh parsing: `!`, `$`, `` ` ``, `|`, `&`, `;`, `'`, `"`, `>`, `<`, `*`, `?`, `(`, `)`, etc.
  - Use one simple `git` command per line (no chaining with `&&` or `;`).