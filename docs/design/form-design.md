# Form Design Guide (v1.1)

**Core rule:** Every field is a cost.

## 1. Defaults
- Single-column layout
- Top-aligned labels
- One primary action
- Validate on blur

## 2. Layout
- Max width ~640px
- Multi-column only for tightly coupled fields
- Never hide required fields

## 3. Labels
- Always visible
- Concise nouns
- Sentence case
- Placeholders are hints, not labels

## 4. Inputs
- Width matches expected input
- Height 40–44px
- Correct HTML types
- Clear focus and error states

## 5. Grouping
- Spacing communicates structure
- Fieldsets + legends where needed
- Headings for sections

## 6. Required vs Optional
- Prefer marking optional fields
- One system only
- Never color alone

## 7. Validation & Errors
- After interaction
- Explain what + how to fix
- Focus first error on submit
- Inline errors are assertive live regions by default (`role="alert"` + `aria-live="assertive"`)
- `announce_errors={false}` is licensed only when the form supplies deterministic
  submit-time focus plus an associated `aria-describedby` description or a focusable
  error summary; the error id, text, and description wiring never change

## 8. Actions
- One dominant primary
- Secondary actions subdued
- Don’t disable submit to hide errors

## 9. Accessibility
- Programmatic labels
- Keyboard operable
- Works at 320px width

## 10. Final Test
1. Can I remove a field?
2. Is the path obvious?
3. No mouse required?
