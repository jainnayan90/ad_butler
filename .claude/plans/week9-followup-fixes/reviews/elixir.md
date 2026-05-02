# Code Review: week9-followup-fixes (elixir-reviewer)

> **⚠️ EXTRACTED FROM AGENT MESSAGE** — agent reported "cannot write directly"; orchestrator captured the chat output verbatim. See `scratchpad.md` 2026-05-02 entry.

## Summary
- **Status**: Approved
- **Issues Found**: 3 (0 BLOCKER, 1 WARNING, 2 NIT)

---

## Warnings

### 1. `kind_of/1` clause ordering — scratchpad inverts the code

`server.ex:351-354` — The **implementation is correct**: `is_struct` comes before `is_map` (structs satisfy `is_map/1` so the reverse order would shadow the struct clause silently). However, the plan's scratchpad lists them in the inverted order (`map` → `is_struct`). No bug today, but a future editor following the scratchpad description could accidentally reorder the clauses and introduce a latent defect where struct shapes are classified as `"map"` instead of the module name.

**Fix**: Add a one-line comment above the `kind_of/1` clauses — `# is_struct must precede is_map — all structs satisfy is_map/1` — or correct the scratchpad description.

---

## NITs

### 2. `format_tool_results/2` public visibility not self-documented

`server.ex:356-375` — `@doc false` on a `def` keeps it out of ExDoc but the function remains callable from any module as `Server.format_tool_results(...)`. The test legitimately uses this. The intent is sound (D-FU decisions noted in scratchpad). A one-line comment — `# Public only for unit testing — do not call from outside Chat.Server` — would make the intent self-documenting and forestall a future Credo `ModuleAttributeInGuard` or similar nit from a reviewer who doesn't know the history.

**Severity: NIT**

### 3. `check_chat_unsafe.sh` — `cmd` invocation relies on execute bit

`mix.exs:114` calls `cmd scripts/check_chat_unsafe.sh`. This requires the git execute bit to be set. On some CI environments (Windows, zip-extracted repos) the bit is lost and the script silently fails to execute. `cmd bash scripts/check_chat_unsafe.sh` is more portable. The path-anchored fix for the prior `--exclude basename` issue is **fully sound** — verified at `check_chat_unsafe.sh:9-10`.

**Severity: NIT**

---

## Verification of Prior Review Finding (RESOLVED)

The prior review pass flagged `--exclude` basename matching as letting a future `lib/foo/server.ex` silently bypass the gate. The fix at `scripts/check_chat_unsafe.sh:9-10` uses `grep -v '^lib/ad_butler/chat/server.ex:'` which is path-anchored from the repo root. This correctly rejects any file whose path does not start with that exact prefix. **RESOLVED.**

---

## Pre-existing Code (unchanged hunks)

- `server.ex:320-327` `normalise_params/1` — `String.to_existing_atom` with `rescue ArgumentError` is safe; LLM arg maps use known tool-param atoms.
- `server.ex:466-469` `stream_from_handle/1` — catch-all pass-through pre-existing; out of scope.
- `message.ex:68-76` `validate_content_required/1` — `if` over pattern-matching function heads; pre-existing style smell, not a regression.
