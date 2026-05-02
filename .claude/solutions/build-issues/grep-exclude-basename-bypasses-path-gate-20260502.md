---
module: "Mix aliases — `check.unsafe_callers` and similar grep-based architecture gates"
date: "2026-05-02"
problem_type: anti_pattern
component: build_tooling
symptoms:
  - "`mix check.unsafe_callers` (or any `grep --exclude` based gate) passes locally but a future file at `lib/foo/server.ex` calling the forbidden API silently slips through"
  - "Reviewer flags the gate as 'fragile' — basename match would exempt unrelated files"
  - "Two files share a basename across paths and the exclusion semantics are surprising"
root_cause: "GNU/BSD `grep --exclude=PATTERN` matches the BASENAME suffix, not the full path. Excluding `--exclude='server.ex'` whitelists every `server.ex` anywhere in the repo, present or future. Path-anchored exclusion needs a different mechanism — `find -path`, `grep -v '^path/to/file:'`, or `git ls-files | grep -v`."
severity: high
tags: [build, mix-aliases, grep, architecture-gates, security, ad-butler]
---

# `grep --exclude=basename` Bypasses Path-Anchored Architecture Gates

## Symptoms

A mix alias guards a load-bearing architectural rule (e.g. "`Chat.unsafe_*` may
only be called from `lib/ad_butler/chat/server.ex` or `lib/ad_butler/chat.ex`").
The first iteration looks reasonable:

```elixir
"check.unsafe_callers": [
  "cmd ! grep -rn 'Chat\\.unsafe_' lib --include='*.ex' \
    --exclude='server.ex' --exclude='chat.ex' \
    || (echo 'ERROR: ...' && exit 1)"
]
```

Today the gate passes (because the only call sites are in those two files).
Tomorrow someone adds `lib/ad_butler/billing/server.ex` and starts calling
`Chat.unsafe_get_session_user_id/1` — the gate still passes, because
`--exclude='server.ex'` matches the new file's basename too.

## Root Cause

`grep --exclude=GLOB` matches against the BASENAME of the file, not its full
path. From the GNU grep man page:

> `--exclude=GLOB`
> Skip any command-line file with a name suffix that matches the pattern GLOB.

`'server.ex'` has no path separators, so it matches every file named exactly
`server.ex` regardless of directory. The original intent — "exempt these two
specific files by path" — cannot be expressed with `--exclude` alone.

A second, subtler hazard: `! grep ...` flips on the exit status. If grep itself
errors out (a malformed flag, a missing file, a BSD-vs-GNU divergence), exit
code 2 also flips to "success" under `!`. The gate then passes vacuously
without any output to indicate it never ran the intended check.

## Fix

Move the gate into a real shell script with explicit path-anchored filtering:

```bash
# scripts/check_chat_unsafe.sh
#!/usr/bin/env bash
set -e

matches=$(grep -rn 'Chat\.unsafe_' lib --include='*.ex' \
  | grep -v '^lib/ad_butler/chat/server.ex:' \
  | grep -v '^lib/ad_butler/chat.ex:' \
  || true)

if [ -n "$matches" ]; then
  echo "$matches"
  echo "ERROR: Chat.unsafe_ called outside Chat.Server / Chat context"
  exit 1
fi
```

Then the alias is one line:

```elixir
"check.unsafe_callers": [
  "cmd ! grep -rn 'Ads\\.unsafe_' lib/ad_butler_web || (echo '...' && exit 1)",
  "cmd scripts/check_chat_unsafe.sh"
]
```

Why this fixes it:

1. **`grep -v '^path/to/file:'` is path-anchored.** A `lib/foo/server.ex`
   match doesn't start with `lib/ad_butler/chat/server.ex:` and so isn't
   excluded.
2. **`set -e` + explicit exit.** A grep error halts the script with a real
   non-zero exit instead of being swallowed by `! grep`.
3. **`grep -rn lib --include=*.ex` (no trailing slash on `lib`).** With
   `lib/`, output paths begin `lib//ad_butler/...` (double slash) and the
   anchored `grep -v '^lib/ad_butler/...:'` filter misses them. Drop the
   trailing slash to keep output paths canonical.

## Prevention

- For any architectural gate, write the rule out as an executable script with
  a self-test in the same directory. The script should be runnable and
  testable in isolation.
- Path-based filters belong in `grep -v '^path:'` or `find -path`, never in
  `grep --exclude`.
- Don't rely on `! cmd` semantics for multi-stage pipelines — explicit
  `if/then/exit` is unambiguous.
- Verify the gate fires by adding a known-bad call site, running the gate,
  and reverting. The plan calls this out (P4-T2 in week9-followup-fixes) but
  it's worth doing for every new gate, not just chat-specific ones.

## Related

- `.claude/solutions/ecto/partial-unique-index-breaks-on-conflict-20260425.md`
  — another case where the wrong assumption about a database mechanism passes
  silently until it doesn't.
