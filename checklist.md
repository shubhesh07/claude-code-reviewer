# Pre-Landing Review Checklist

Based on [gstack](https://github.com/garrytan/gstack) review methodology.

## Instructions

Review the diff for the issues listed below. Be specific — cite `file:line` and suggest fixes. Skip anything that's fine. Only flag real problems.

**Two-pass review:**
- **Pass 1 (CRITICAL):** Run these first. These are blocking issues that must be addressed.
- **Pass 2 (INFORMATIONAL):** Run all remaining categories. These are worth noting but non-blocking.

**Output format:**

```
Review: N issues (X critical, Y informational)

**CRITICAL** (blocking):
- [file:line] Problem description
  Fix: suggested fix

**Issues** (non-blocking):
- [file:line] Problem description
  Fix: suggested fix
```

If no issues found: `Review: No issues found. LGTM`

Be terse. For each issue: one line describing the problem, one line with the fix. No preamble, no summaries, no "looks good overall."

---

## Review Categories

### Pass 1 — CRITICAL

#### SQL & Data Safety
- String interpolation/concatenation in SQL queries — use parameterized queries or prepared statements
- TOCTOU races: check-then-set patterns that should be atomic operations
- Bypassing ORM validations on fields that have or should have constraints
- N+1 queries: missing eager loading for associations used in loops
- Missing transaction boundaries around multi-step data mutations

#### Race Conditions & Concurrency
- Read-check-write without uniqueness constraint or conflict handling
- Find-or-create patterns on columns without unique index — concurrent calls can create duplicates
- Status transitions without atomic compare-and-swap — concurrent updates can skip or double-apply
- Shared mutable state accessed without synchronization (locks, mutexes, channels)
- Goroutine/thread leaks — unbounded spawning without cancellation

#### Injection & Trust Boundaries
- User-controlled data passed to `html_safe`/`raw()`, `eval()`, `exec()`, `os.system()`, template engines, or shell commands without sanitization
- LLM-generated values (emails, URLs, names) written to DB or passed to mailers without format validation
- Structured tool output (arrays, objects) accepted without type/shape checks before database writes
- Missing authentication or authorization checks on new endpoints
- Hardcoded secrets, credentials, or API keys in code

### Pass 2 — INFORMATIONAL

#### Conditional Side Effects
- Code paths that branch on a condition but forget to apply a side effect on one branch (e.g., record updated on one path but not the other, creating inconsistent state)
- Log messages that claim an action happened but the action was conditionally skipped

#### Magic Numbers & String Coupling
- Bare numeric literals used in multiple files — should be named constants
- Error message strings used as query filters elsewhere (grep for the string — is anything matching on it?)

#### Dead Code & Consistency
- Variables assigned but never read
- Comments/docstrings that describe old behavior after the code changed
- Version mismatch between PR title and VERSION/CHANGELOG files

#### Error Handling
- Swallowed errors (caught but not logged, returned, or handled)
- Missing error checks on I/O, network calls, type assertions
- Panics/exceptions that should be recoverable errors
- Missing cleanup/rollback on partial failure

#### Test Gaps
- Negative-path tests that assert type/status but not the side effects
- Security enforcement features (blocking, rate limiting, auth) without integration tests
- Missing `.expects(:something).never` / mock verification when a code path should NOT call an external service

#### Performance
- N+1 queries or unbounded DB fetches
- Expensive operations inside loops (allocations, API calls, regex compilation)
- Missing pagination on list endpoints
- Large payloads without streaming or size limits

#### API Contracts
- Breaking changes to public APIs without versioning
- Request/response schema mismatches
- Missing validation on required fields

#### LLM Prompt Issues
- 0-indexed lists in prompts (LLMs reliably return 1-indexed)
- Prompt text listing available tools/capabilities that don't match what's actually wired up in the code
- Word/token limits stated in multiple places that could drift out of sync

#### Crypto & Entropy
- Truncation of data instead of hashing (last N chars instead of SHA-256) — less entropy, easier collisions
- `rand()` / `Math.random()` / `Random.rand` for security-sensitive values — use crypto-secure RNG
- Non-constant-time comparisons (`==`) on secrets or tokens — vulnerable to timing attacks

#### Time Window Safety
- Date-key lookups that assume "today" covers 24h — a report at 8am only sees midnight→8am under today's key
- Mismatched time windows between related features — one uses hourly buckets, another uses daily keys for the same data

#### Type Coercion at Boundaries
- Values crossing language/serialization boundaries where type could change (numeric vs string) — hash/digest inputs must normalize types
- Hash/digest inputs that don't call `.toString()` or equivalent before serialization — `{ cores: 8 }` vs `{ cores: "8" }` produce different hashes

---

## Gate Classification

```
CRITICAL (blocking):                 INFORMATIONAL (non-blocking):
├─ SQL & Data Safety                 ├─ Conditional Side Effects
├─ Race Conditions & Concurrency     ├─ Magic Numbers & String Coupling
└─ Injection & Trust Boundaries      ├─ Dead Code & Consistency
                                     ├─ Error Handling
                                     ├─ Test Gaps
                                     ├─ Performance
                                     ├─ API Contracts
                                     ├─ LLM Prompt Issues
                                     ├─ Crypto & Entropy
                                     ├─ Time Window Safety
                                     └─ Type Coercion at Boundaries
```

---

## Suppressions — DO NOT flag these

- Redundant checks that aid readability (e.g., `present?` redundant with length check)
- "Add a comment explaining why this threshold was chosen" — thresholds change during tuning, comments rot
- "This assertion could be tighter" when the assertion already covers the behavior
- Consistency-only changes (reformatting to match surrounding code style, wrapping a value in a conditional to match another constant)
- "Regex doesn't handle edge case X" when the input is constrained and X never occurs in practice
- "Test exercises multiple guards simultaneously" — that's fine, tests don't need to isolate every guard
- Eval threshold changes (max_actionable, min scores) — these are tuned empirically and change constantly
- Harmless no-ops (e.g., `.reject` on an element that's never in the array)
- Style preferences, naming conventions, or nitpicks
- ANYTHING already addressed in the diff you're reviewing — read the FULL diff before commenting
