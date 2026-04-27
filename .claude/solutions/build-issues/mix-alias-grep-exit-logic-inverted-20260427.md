---
module: "mix.exs aliases"
date: "2026-04-27"
problem_type: logic_error
component: configuration
symptoms:
  - "mix precommit passes even when Ads.unsafe_ is called from web layer"
  - "grep finds violations but mix alias reports success"
  - "check.unsafe_callers never blocks a commit"
root_cause: "Shell operator precedence: `grep && exit 1 || exit 0` parses as `(grep && exit 1) || exit 0` — when grep matches and exit 1 fires, `|| exit 0` catches the non-zero exit and the alias exits 0 regardless"
severity: high
tags: ["mix-alias", "shell", "grep", "ci-check", "exit-code", "precommit"]
---

# mix alias grep gate always passes due to inverted `|| exit 0` shell logic

## Symptoms

A `check.unsafe_callers` alias was added to prevent `Ads.unsafe_*` calls from
appearing in web-layer files. The alias ran without error even when violations
existed. `mix precommit` never blocked a commit.

## Investigation

1. **Checked mix output** — alias ran, printed nothing, exited 0
2. **Ran grep manually** — found matches as expected
3. **Root cause found**: shell operator precedence

## Root Cause

The problematic pattern:

```sh
grep -rn 'Ads\.unsafe_' lib/ad_butler_web && echo 'ERROR...' && exit 1 || exit 0
```

Shell parses this left-to-right with `||` having lower precedence than `&&`:

```
(grep ... && echo 'ERROR' && exit 1) || exit 0
```

When `grep` finds a match:
- `echo 'ERROR'` runs ✓
- `exit 1` runs — but this exits the subcommand, not `mix cmd`
- `|| exit 0` then fires because the left side had a non-zero exit
- Mix alias exits 0 — **check passes silently**

Also: `lib/ad_butler/sync` was included in the scan paths, which would flag
legitimate internal callers (`InsightsPipeline.fetch_and_upsert/4`) once the
logic was fixed.

## Solution

Use `!` negation operator — invert grep match logic, scope to web layer only:

```sh
# WRONG — always exits 0
grep -rn 'Ads\.unsafe_' lib/ad_butler_web && echo 'ERROR' && exit 1 || exit 0

# CORRECT — exits 1 when grep finds a match
! grep -rn 'Ads\.unsafe_' lib/ad_butler_web || (echo 'ERROR: Ads.unsafe_ called from web layer' && exit 1)
```

In `mix.exs`:

```elixir
"check.unsafe_callers": [
  "cmd ! grep -rn 'Ads\\.unsafe_' lib/ad_butler_web || (echo 'ERROR: Ads.unsafe_ called from web layer' && exit 1)"
],
```

**Key scoping rule**: Only scan `lib/ad_butler_web`. The sync pipeline and
workers legitimately call `unsafe_*` functions — they are trusted internal callers.
The gate is specifically for accidental leakage into the HTTP-facing layer.

### Files Changed

- `mix.exs` — Fixed grep logic, scoped to `lib/ad_butler_web`

## Prevention

- [ ] When writing `mix cmd grep ... && exit 1`, always use `! grep ... || exit 1` instead
- [ ] Scope grep CI checks to the narrowest relevant directory
- [ ] Test new CI aliases by running them with a deliberate violation before merging

Specific guidance: "Any `mix cmd` alias that uses `grep ... && exit 1 || exit 0` 
has inverted logic. The correct pattern is `! grep ... || (echo MSG && exit 1)`."
