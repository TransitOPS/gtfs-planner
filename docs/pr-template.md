# Pull Request

## Description

<!--
Provide a clear and concise description of your changes.
Focus on the "what" and "why", not just the "how".
Link to any relevant issues, discussions, or documentation.
-->

Closes #<!-- issue number -->

## Type of Change

<!-- Mark the relevant option with an "x" -->

- [ ] 🐛 Bug fix (non-breaking change that fixes an issue)
- [ ] ✨ New feature (non-breaking change that adds functionality)
- [ ] 💥 Breaking change (fix or feature that would cause existing functionality to change)
- [ ] 📚 Documentation update
- [ ] ♻️ Refactor (no functional changes)
- [ ] ⚡ Performance improvement
- [ ] 🧪 Test addition or update
- [ ] 🔧 Configuration or build change

---

## Context & Motivation

<!--
Why is this change needed? What problem does it solve?
Include any relevant background that helps reviewers understand the context.
-->

## Solution Approach

<!--
Explain your approach and any design decisions you made.
If there were alternative approaches considered, briefly explain why this one was chosen.
-->

---

## Code Quality Checklist

### Functional Design (José Valim's Principles)

<!--
Elixir emphasizes functional programming, immutability, and leveraging OTP patterns.
These checks ensure your code aligns with Elixir's core philosophy.
-->

- [ ] Functions are small, focused, and have clear responsibilities
- [ ] Data transformations use pipelines (`|>`) where it improves readability
- [ ] Pattern matching is used effectively (function heads, case, with)
- [ ] No unnecessary side effects; side effects are isolated and explicit
- [ ] Appropriate use of OTP patterns (GenServer, Supervisor, etc.) if applicable
- [ ] Error handling uses tagged tuples (`{:ok, result}` / `{:error, reason}`) consistently
- [ ] No reinvention of standard library functions

### Phoenix & Web Layer (Chris McCord's Principles)

<!--
Phoenix emphasizes clean context boundaries, explicit over implicit,
and leveraging Elixir's concurrency for real-time features.
-->

- [ ] Context boundaries are respected (business logic in contexts, not controllers)
- [ ] Controllers are thin; complex logic delegated to contexts or services
- [ ] Changesets validate data at the boundary
- [ ] LiveView components are focused and reusable (if applicable)
- [ ] PubSub/Channels used appropriately for real-time features (if applicable)
- [ ] Plugs are used for cross-cutting concerns
- [ ] Routes follow RESTful conventions or are clearly documented

### Tooling & Infrastructure (Wojtek Mach's Principles)

<!--
Robust tooling, observability, and maintainable dependencies are
crucial for long-term project health.
-->

- [ ] Telemetry events added for observability (where appropriate)
- [ ] Dependencies are justified and from trusted sources
- [ ] No unnecessary dependencies added
- [ ] Req/HTTP clients configured with appropriate timeouts and retries
- [ ] Database queries are efficient (checked with `EXPLAIN ANALYZE` if complex)

---

## Testing

### Test Coverage

- [ ] Unit tests cover new/changed functions
- [ ] Integration tests cover new/changed user flows
- [ ] Edge cases and error paths are tested
- [ ] Tests are deterministic (no race conditions, no reliance on external state)
- [ ] Async tests properly use `async: true` or `async: false` as appropriate

### Test Quality

<!--
Good tests are documentation. They should be readable and express intent.
-->

- [ ] Test names clearly describe the behavior being tested
- [ ] Tests follow Arrange-Act-Assert pattern
- [ ] Fixtures/factories are used appropriately (no excessive setup)
- [ ] No tests skipped without explanation
- [ ] ExUnit tags used appropriately for slow/integration tests

### Test Commands

```bash
# Confirm all tests pass
mix test

# Confirm tests pass with warnings as errors
mix test --warnings-as-errors

# Run only the tests affected by this PR (if applicable)
mix test path/to/specific_test.exs
```

---

## Database & Migrations

<!-- Skip this section if no database changes -->

- [ ] Migration is reversible (has a working `down/0` callback)
- [ ] Migration is safe for zero-downtime deploys (no table locks on large tables)
- [ ] Indexes added for frequently queried columns
- [ ] Migration tested against production-like data volume
- [ ] Ecto schemas updated to reflect database changes
- [ ] Seeds updated if applicable

### Migration Safety Checklist

- [ ] No `DROP COLUMN` without a prior release removing code references
- [ ] No `RENAME` operations (use add → migrate → remove pattern instead)
- [ ] Large data migrations are done in batches
- [ ] New columns have sensible defaults or are nullable

---

## Performance Considerations

<!-- Skip if not applicable -->

- [ ] No N+1 queries introduced (use `preload` appropriately)
- [ ] Large datasets use `Repo.stream/2` or pagination
- [ ] Expensive operations are async or backgrounded (Oban, Task, etc.)
- [ ] Caching considered for frequently accessed, rarely changed data
- [ ] LiveView optimizations applied (temporary assigns, streams for lists)

### Benchmarks

<!-- If this PR affects performance-critical code, include benchmark results -->

```elixir
# Example benchmark command
mix run benchmarks/my_benchmark.exs
```

---

## Documentation

- [ ] `@moduledoc` added/updated for new/changed modules
- [ ] `@doc` added/updated for public functions
- [ ] `@spec` typespecs added for public functions
- [ ] README updated (if applicable)
- [ ] CHANGELOG updated (if applicable)
- [ ] In-code comments explain "why" for non-obvious decisions

---

## Deployment & Operations

### Pre-Deployment

- [ ] Environment variables documented (if new ones added)
- [ ] Configuration changes noted and communicated
- [ ] Feature flags in place for gradual rollout (if applicable)

### Rollback Plan

<!-- How do we revert this change if something goes wrong? -->

- [ ] Migration is reversible
- [ ] No breaking API changes (or version bump if so)
- [ ] Rollback steps documented (if complex)

### Monitoring

- [ ] Relevant Telemetry events for dashboards/alerts
- [ ] Log messages are appropriate (level, content, no sensitive data)
- [ ] Error tracking integration (if applicable)

---

## Security Considerations

<!-- Skip if not applicable -->

- [ ] User input is validated and sanitized
- [ ] No SQL injection vulnerabilities (use parameterized queries)
- [ ] No XSS vulnerabilities (Phoenix handles this, but verify custom HTML)
- [ ] Authorization checks in place for protected resources
- [ ] Sensitive data not logged or exposed
- [ ] Secrets not hardcoded

---

## Screenshots / Recordings

<!-- If this PR includes UI changes, add screenshots or recordings here -->

| Before | After |
| ------ | ----- |
|        |       |

---

## Reviewer Notes

<!--
Anything specific you'd like reviewers to focus on?
Areas of uncertainty? Alternative approaches to consider?
-->

### Focus Areas

-

### Questions for Reviewers

-

---

## Pre-Merge Checklist

- [ ] Branch is up to date with `main`
- [ ] All CI checks pass
- [ ] `mix format` has been run
- [ ] `mix credo --strict` passes (or warnings addressed)
- [ ] `mix dialyzer` passes (if project uses Dialyzer)
- [ ] Self-review completed
- [ ] PR title follows conventional commits (if applicable)

---

## Post-Merge Tasks

<!-- Any tasks that need to happen after this PR is merged? -->

- [ ] Notify team in Slack/Discord
- [ ] Update project board/tracking
- [ ] Schedule deployment
- [ ] Other:
