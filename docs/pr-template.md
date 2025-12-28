# Pull Request

## Summary

<!-- What changed + why (1–3 sentences). Link issues/docs if helpful. -->

Closes #

## Type

- [ ] Bug fix
- [ ] Feature
- [ ] Breaking change
- [ ] Refactor
- [ ] Docs
- [ ] Chore / Build / Config
- [ ] Tests

## Notes for Reviewers

<!-- Anything you want reviewers to focus on, tradeoffs, or risk areas. -->

- Focus:
- Risk / rollout:
- Follow-ups:

## Verification

<!-- How you know it works (tests run + manual checks). -->

- Tests:
  - [ ] `mix test`
  - [ ] Other:
- Local/manual check:
  - [ ] N/A
  - [ ] Describe:

## Checklist

- [ ] `mix format` run
- [ ] Credo addressed (if used): `mix credo --strict`
- [ ] No secrets/config in code or logs
- [ ] Errors handled idiomatically (`{:ok, _}` / `{:error, _}`); side effects are explicit
- [ ] Phoenix boundary respected (controllers/live views thin; logic in contexts)

<details>
<summary>Optional: DB / Migrations</summary>

- [ ] Migration included (or N/A)
- [ ] Safe-ish migration (no big locks / risky rewrites)
- [ ] Backfill/cleanup plan if needed
- [ ] Reversible where feasible

</details>

<details>
<summary>Optional: UI (Screenshots)</summary>

| Before | After |
| ------ | ----- |
|        |       |

</details>

<details>
<summary>Optional: Performance / Ops</summary>

- [ ] No obvious N+1 / expensive queries introduced
- [ ] Telemetry/logging added/adjusted (if relevant)
- [ ] Deployment/rollback note (if relevant)

</details>
